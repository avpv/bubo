import EventKit
import Foundation
import os

/// Mirrors the file-scope `logger` in `RemindersSyncService.swift` so
/// writeback failures emit under the same subsystem/category. Duplicated
/// rather than promoted to module-internal because the logger is purely
/// implementation detail.
private let logger = Logger(subsystem: "com.avpv.Bubo", category: "RemindersSyncService")

// MARK: - RemindersSyncService writeback paths (Bubo → Apple Reminders)
//
// Inverse direction of `Sync` (which pulls EventKit changes into the
// backlog). This extension owns the export of new backlog tasks into
// Apple Reminders, plus completion / edit / schedule / remove
// propagation, plus the linkage-id helpers that stamp the cross-system
// pairing on each task.
//
// Every method that touches `EKEventStore.saveReminder` brackets the
// call with `markSelfWrite()` so the next remote-change notification
// from EventKit doesn't bounce back through `Sync` and re-import the
// task we just exported.
//
// Extracted from `RemindersSyncService.swift`; visibility on a handful
// of stored properties and statics was relaxed from `private` to
// internal so this sibling file can read/write them — every such
// change is annotated on the declaration site.

extension RemindersSyncService {

    // MARK: - Completion Writeback

    /// Called when the user marks a task done in Bubo. If the task is linked
    /// to an Apple Reminder (imported or exported) and the user opted into
    /// completion writeback, marks the source reminder done too.
    private func handleTaskCompleted(taskId: String) {
        guard settings.remindersCompletionSync else { return }
        guard let calendarItemId = linkedCalendarItemId(for: taskId) else { return }

        markSelfWrite()
        do {
            try remindersSource.completeReminder(calendarItemId: calendarItemId)
        } catch {
            logger.error("Failed to complete reminder in Apple Reminders: \(error)")
        }
    }

    // MARK: - Export (Bubo → Reminders)

    /// Called when a new task is added to the backlog. If the user opted into
    /// export, creates a matching reminder in Apple Reminders and stores its
    /// `calendarItemIdentifier` on the task.
    ///
    /// Skipped for reminder-backed tasks (prefix `reminder_`) — they already
    /// exist in Apple Reminders — and for any task that already has a linked
    /// reminder from a previous export run.
    private func handleTaskAdded(taskId: String) {
        guard settings.remindersExportEnabled,
              remindersSource.hasAccess else { return }

        // Already on the Reminders side — don't double-push.
        if taskId.hasPrefix("reminder_") { return }

        guard let task = backlogService.tasks.first(where: { $0.id == taskId }),
              task.reminderCalendarItemId == nil
        else { return }

        markSelfWrite()
        do {
            // Prefer the user's currently-active project list (set via the
            // backlog header's project picker) over the global default
            // export list. This matches the Reminders.app UX: «a new task
            // goes where I'm looking». `activeRemindersListId` returns
            // nil for `.all` and for local Bubo projects — local projects
            // don't map to any EK list, so the export falls through to the
            // user's global `remindersExportListId`.
            let targetListId = settings.activeRemindersListId
                ?? settings.remindersExportListId
            let calendarItemId = try remindersSource.createReminder(
                from: task,
                inListId: targetListId
            )
            // Persist the linkage so later syncs can dedupe and so completion
            // / scheduling writeback can find the right reminder.
            backlogService.silentlyUpdateReminderMapping(
                taskId: taskId,
                calendarItemId: calendarItemId
            )
        } catch {
            logger.error("Failed to export task to Apple Reminders: \(error)")
        }
    }

    // MARK: - Edit Writeback

    /// Called whenever the user mutates a linked task in Bubo. Pushes the
    /// updated title / priority / deadline / context to Apple Reminders so
    /// the reminder stays in sync with the backlog.
    ///
    /// `AppleRemindersService.updateReminder` does field-level diffing, so
    /// an echo of a just-imported remote edit is a no-op — no redundant save,
    /// no extra `EKEventStoreChanged` fires.
    private func handleTaskUpdated(taskId: String) {
        guard remindersSource.hasAccess,
              let task = backlogService.tasks.first(where: { $0.id == taskId }),
              let calendarItemId = calendarItemId(for: task) else {
            return
        }

        markSelfWrite()
        do {
            try remindersSource.updateReminder(
                calendarItemId: calendarItemId,
                from: task
            )
        } catch {
            logger.error("Failed to push task edit to Apple Reminders: \(error)")
        }
    }

    // MARK: - Schedule Writeback

    /// Called when a linked task is placed into (or removed from) a Bubo
    /// schedule slot. Writes the scheduled time back as the reminder's due
    /// date so the schedule shows up in Reminders.app on other devices.
    /// When the task is un-scheduled, falls back to its remaining deadline
    /// (or clears the due date entirely if there's no deadline).
    private func handleTaskScheduleChanged(taskId: String) {
        guard remindersSource.hasAccess,
              let task = backlogService.tasks.first(where: { $0.id == taskId }),
              let calendarItemId = calendarItemId(for: task) else {
            return
        }

        let newDueDate = task.scheduledDate ?? task.deadline
        let alarmDates = scheduleAlarmDates(forDueDate: newDueDate)
        markSelfWrite()
        do {
            try remindersSource.updateReminderSchedule(
                calendarItemId: calendarItemId,
                dueDate: newDueDate,
                alarmDates: alarmDates
            )
        } catch {
            logger.error("Failed to push scheduling to Apple Reminders: \(error)")
        }
    }

    /// Compute the absolute fire-dates for `EKAlarm`s on a scheduled
    /// reminder. Returns an empty array — meaning "clear all alarms" — if
    /// the user hasn't opted in, the date is missing, the date has no
    /// meaningful time component (all-day / date-only — we won't ring the
    /// user's phone at midnight), or every computed alarm falls in the
    /// past.
    ///
    /// When opted in, the at-time alarm is anchored to `dueDate` and one
    /// extra alarm is added for each enabled lead-time interval. Past
    /// fire-dates are dropped silently — EventKit can otherwise fire them
    /// the moment they're saved.
    func scheduleAlarmDates(forDueDate dueDate: Date?) -> [Date] {
        guard settings.remindersScheduleAlarms,
              let dueDate else { return [] }
        guard hasMeaningfulTime(dueDate) else { return [] }

        var dates: [Date] = [dueDate]
        for interval in settings.remindersScheduleAlarmLeadMinutes where interval.isEnabled {
            let lead = TimeInterval(interval.minutes) * 60
            dates.append(dueDate.addingTimeInterval(-lead))
        }
        let now = Date()
        return dates.filter { $0 > now }
    }

    /// True when `date` carries hour/minute/second information beyond
    /// midnight local time. Mirrors the all-day check used by
    /// `AppleRemindersService.dueDateComponents(from:)` so the two layers
    /// agree on what counts as a date-only deadline.
    private func hasMeaningfulTime(_ date: Date) -> Bool {
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return (comps.hour ?? 0) != 0
            || (comps.minute ?? 0) != 0
            || (comps.second ?? 0) != 0
    }

    /// Re-run the schedule writeback for every currently scheduled linked
    /// task whenever the alarm-related settings change. Compares against
    /// the last-known snapshot and bails when unrelated settings changed.
    /// Issues one batched EventKit transaction so toggling the alarm
    /// policy on a populated backlog produces a single commit instead of
    /// one save per task.
    private func handleAlarmSettingsChangedIfNeeded() {
        let snapshot = Self.alarmSnapshot(from: settings)
        guard snapshot != lastAlarmSettingsSnapshot else { return }
        lastAlarmSettingsSnapshot = snapshot

        guard remindersSource.hasAccess else { return }

        let updates: [ScheduleUpdate] = backlogService.tasks.compactMap { task in
            guard task.scheduledDate != nil,
                  let calendarItemId = calendarItemId(for: task) else {
                return nil
            }
            let dueDate = task.scheduledDate ?? task.deadline
            return ScheduleUpdate(
                calendarItemId: calendarItemId,
                dueDate: dueDate,
                alarmDates: scheduleAlarmDates(forDueDate: dueDate)
            )
        }

        guard !updates.isEmpty else { return }

        markSelfWrite()
        do {
            try remindersSource.applyScheduleUpdates(updates)
        } catch {
            logger.error("Failed to sweep schedule alarms in Apple Reminders: \(error)")
        }
    }

    private static func alarmSnapshot(from settings: ReminderSettings) -> AlarmSettingsSnapshot {
        AlarmSettingsSnapshot(
            enabled: settings.remindersScheduleAlarms,
            leadMinutes: settings.remindersScheduleAlarmLeadMinutes
                .filter(\.isEnabled)
                .map(\.minutes)
                .sorted()
        )
    }

    // MARK: - Remove Writeback

    /// Called whenever a task leaves the backlog. Imported tasks are added
    /// to the dismissed set so they don't re-import; exported / imported
    /// tasks with a linked reminder are deleted from Apple Reminders when
    /// the user opted into deletion sync.
    private func handleTaskRemoved(_ removed: BacklogTask) {
        // Imported reminder → remember so we don't re-import next sync.
        if removed.id.hasPrefix("reminder_") {
            dismissedReminderIds.insert(removed.id)
        }

        // Delete the linked reminder when opt-in is on.
        guard settings.remindersDeletionSync,
              remindersSource.hasAccess,
              let calendarItemId = calendarItemId(for: removed) else {
            return
        }

        markSelfWrite()
        do {
            try remindersSource.deleteReminder(calendarItemId: calendarItemId)
        } catch {
            logger.error("Failed to delete reminder in Apple Reminders: \(error)")
        }
    }

    // MARK: - Linkage Helpers

    /// Returns the Apple Reminders `calendarItemIdentifier` linked to a task,
    /// whether it was imported (prefix) or exported (stored on the task).
    private func calendarItemId(for task: BacklogTask) -> String? {
        if let imported = AppleRemindersService.remindersId(from: task.id) {
            return imported
        }
        return task.reminderCalendarItemId
    }

    /// Look up the task and resolve its linked calendar-item identifier.
    /// Kept as a convenience for handlers that only have the task ID.
    private func linkedCalendarItemId(for taskId: String) -> String? {
        guard let task = backlogService.tasks.first(where: { $0.id == taskId }) else {
            return nil
        }
        return calendarItemId(for: task)
    }

    /// Bump the self-write suppression window so the `.EKEventStoreChanged`
    /// echo from our own EventKit write doesn't trigger a re-sync.
    private func markSelfWrite() {
        suppressRemoteChangesUntil = Date().addingTimeInterval(Self.selfWriteSuppressionInterval)
    }
}
