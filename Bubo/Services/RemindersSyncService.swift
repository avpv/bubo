import Foundation
import os

/// Bridges Apple Reminders and the Bubo backlog.
///
/// Design mirrors `ReminderService` for calendar events:
///   - Always instantiated in `App.init`; never does EventKit work on init.
///   - `syncNow()` short-circuits when the feature is disabled or Reminders
///     access hasn't been granted — the popover can always open.
///   - Triggered explicitly from `MenuBarView.onAppear` via `startSync()`,
///     the same pattern as `reminderService.startSync()`.
///
/// Behaviours:
///   - **Import** (Reminders → Bubo): incomplete reminders from the
///     selected lists are added to the backlog, deduped by task ID.
///   - **Edit merge** (Reminders → Bubo): when a reminder is edited
///     externally (title / priority / deadline / context), the backlog
///     task picks up the change on the next sync while preserving
///     Bubo-owned fields like duration and scheduled slot.
///   - **External completion mirroring** (Reminders → Bubo): when a
///     reminder-backed task exists in Bubo but its source reminder is no
///     longer incomplete (user finished or deleted it in Reminders.app or
///     on another device), the Bubo task is silently marked done.
///   - **Dismissal tracking**: when the user removes a reminder-backed
///     task from the Bubo backlog, its ID is remembered so future syncs
///     don't re-import it. The set is pruned when the source reminder is
///     completed / deleted in Apple Reminders.
///   - **Export** (Bubo → Reminders): when enabled, every new
///     Bubo-native task is created as a reminder in the user's chosen
///     list. The linked `calendarItemIdentifier` is stored on the task
///     so subsequent syncs dedupe cleanly.
///   - **Edit writeback** (Bubo → Reminders): when the user edits a
///     linked task in Bubo, the reminder picks up the same title /
///     priority / deadline. `updateReminder` does field-level diffing,
///     so echoes of remote edits are no-ops.
///   - **Schedule writeback** (Bubo → Reminders): when a linked task is
///     scheduled (or un-scheduled), its Apple Reminder's due date is
///     set to the scheduled time — so Bubo's schedule shows up in
///     Reminders.app on iPhone / iPad.
///   - **Completion writeback** (Bubo → Reminders): when the user
///     completes a linked task in Bubo, the source Apple Reminder is
///     marked done. Off by default — the user opts in via a toggle.
///   - **Delete writeback** (Bubo → Reminders): when the user removes a
///     linked task, the source Apple Reminder is deleted. Off by
///     default — the user opts in via a separate toggle.
///
/// Self-write suppression: every EventKit write we make triggers an
/// async `EKEventStoreChanged` notification ~100ms later, which would
/// re-enter `syncNow` and potentially double-import the reminder we just
/// created. `suppressRemoteChangesUntil` is a timestamp we bump 2 seconds
/// into the future before every write; inbound change notifications
/// compare against it and skip work when they're our own echo.
private let logger = Logger(subsystem: "com.avpv.Bubo", category: "RemindersSyncService")

@MainActor
@Observable
final class RemindersSyncService {

    /// Posted after a sync imports new tasks. `object` is the count (Int).
    static let didImportTasks = Notification.Name("BuboRemindersDidImportTasks")

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var syncError: String?
    private(set) var importedCount: Int = 0

    /// IDs of reminder-backed tasks the user explicitly removed from the
    /// backlog. We remember these so the next sync doesn't re-import them.
    private(set) var dismissedReminderIds: Set<String> {
        didSet { saveDismissedIds() }
    }

    /// Count of tasks that are being suppressed from future imports. Exposed
    /// so the Settings UI can show the number and offer a "Clear" button.
    var dismissedCount: Int { dismissedReminderIds.count }

    private var settings: ReminderSettings
    private let backlogService: BacklogService
    /// Apple Reminders access abstracted behind a protocol so tests can
    /// drive this service with `FakeRemindersEventSource`. Production
    /// receives `AppleRemindersService.shared`.
    private let remindersSource: any RemindersEventSource

    private nonisolated(unsafe) var syncTimer: Timer?
    private nonisolated(unsafe) var remindersChangedObserver: Any?
    private nonisolated(unsafe) var taskRemovedObserver: Any?
    private nonisolated(unsafe) var taskCompletedObserver: Any?
    private nonisolated(unsafe) var taskAddedObserver: Any?
    private nonisolated(unsafe) var taskUpdatedObserver: Any?
    private nonisolated(unsafe) var taskScheduleChangedObserver: Any?
    private var activeSyncTask: Task<Void, Never>?

    /// Ignore `remindersDataChanged` events that arrive before this time —
    /// they're almost certainly echoes of our own EventKit writes. A simple
    /// boolean flag is race-prone (the notification is asynchronous), so we
    /// use a timestamp and let it expire.
    private var suppressRemoteChangesUntil: Date = .distantPast
    private static let selfWriteSuppressionInterval: TimeInterval = 2.0

    private static let dismissedKey = "BuboDismissedReminderIds"

    init(
        settings: ReminderSettings,
        backlogService: BacklogService,
        remindersSource: any RemindersEventSource = AppleRemindersService.shared
    ) {
        self.settings = settings
        self.backlogService = backlogService
        self.remindersSource = remindersSource
        self.dismissedReminderIds = Self.loadDismissedIds()

        // Listen for external changes (user edits Reminders.app, iCloud sync).
        // The callback short-circuits via `syncNow()` when the feature is off,
        // so this observer is cheap even for users who never enable the sync.
        // Self-writes are filtered via `suppressRemoteChangesUntil` so we
        // don't re-enter sync on our own echoes.
        remindersChangedObserver = NotificationCenter.default.addObserver(
            forName: AppleRemindersService.remindersDataChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Date() < self.suppressRemoteChangesUntil { return }
                self.syncNow()
            }
        }

        // Handle task removals: remember dismissals for imported tasks so we
        // don't re-import them, and optionally delete the linked reminder for
        // exported tasks (opt-in via `remindersDeletionSync`). The full task
        // is delivered as the notification `object` — we need fields like
        // `reminderCalendarItemId` that can't be queried after removal.
        taskRemovedObserver = NotificationCenter.default.addObserver(
            forName: BacklogService.taskRemoved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let removed = notification.object as? BacklogTask else { return }
            Task { @MainActor in
                self?.handleTaskRemoved(removed)
            }
        }

        // Write completion back to Apple Reminders when the user finishes a
        // reminder-backed task in Bubo. Gated by a separate settings toggle.
        taskCompletedObserver = NotificationCenter.default.addObserver(
            forName: BacklogService.taskCompleted,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let taskId = notification.object as? String else { return }
            Task { @MainActor in
                self?.handleTaskCompleted(taskId: taskId)
            }
        }

        // Export Bubo-native tasks to Apple Reminders when the user opted in.
        // Ignored for reminder-backed tasks (they already exist in Reminders)
        // and for any task that already has a `reminderCalendarItemId`.
        taskAddedObserver = NotificationCenter.default.addObserver(
            forName: BacklogService.taskAdded,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let taskId = notification.object as? String else { return }
            Task { @MainActor in
                self?.handleTaskAdded(taskId: taskId)
            }
        }

        // Push Bubo edits (title / priority / deadline / context) to the
        // linked reminder so Reminders.app stays in sync. `AppleRemindersService`
        // does field-level diffing internally, so echo writes are no-ops.
        taskUpdatedObserver = NotificationCenter.default.addObserver(
            forName: BacklogService.taskUpdated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let taskId = notification.object as? String else { return }
            Task { @MainActor in
                self?.handleTaskUpdated(taskId: taskId)
            }
        }

        // When a task is scheduled (or un-scheduled) in Bubo, push the
        // scheduled time as the linked reminder's due date. That's how
        // Bubo's schedule shows up in Reminders.app on iPhone / iPad.
        taskScheduleChangedObserver = NotificationCenter.default.addObserver(
            forName: BacklogService.taskScheduleChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let taskId = notification.object as? String else { return }
            Task { @MainActor in
                self?.handleTaskScheduleChanged(taskId: taskId)
            }
        }
    }

    deinit {
        syncTimer?.invalidate()
        let observers = [
            remindersChangedObserver, taskRemovedObserver,
            taskCompletedObserver, taskAddedObserver,
            taskUpdatedObserver, taskScheduleChangedObserver,
        ].compactMap { $0 }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Update the settings reference. Call when `ReminderSettings` was reloaded
    /// (e.g. from iCloud). Safe to call at any time.
    func updateSettings(_ settings: ReminderSettings) {
        self.settings = settings
    }

    // MARK: - Lifecycle (mirrors ReminderService)

    /// Mirrors `ReminderService.startSync()` — call once from
    /// `MenuBarView.onAppear` after the popover first opens.
    func startSync() {
        syncNow()
        startSyncTimer()
    }

    func startSyncTimer() {
        syncTimer?.invalidate()
        let interval = TimeInterval(settings.syncIntervalMinutes * 60)
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncNow()
            }
        }
    }

    func stopSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    // MARK: - Sync

    func syncNow() {
        guard settings.isRemindersSyncEnabled else {
            syncError = nil
            return
        }

        guard remindersSource.hasAccess else {
            syncError = "Reminders access not granted"
            return
        }

        // Prevent concurrent syncs — cancel any in-flight fetch.
        activeSyncTask?.cancel()

        isSyncing = true
        syncError = nil

        activeSyncTask = Task {
            let fetched = await remindersSource.fetchIncompleteTasks(
                fromListIds: settings.selectedRemindersListIds,
                defaultDuration: settings.remindersDefaultDurationMinutes
            )
            guard !Task.isCancelled else { return }

            let existingById = Dictionary(
                uniqueKeysWithValues: backlogService.tasks.map { ($0.id, $0) }
            )
            // Reverse index: Apple Reminders `calendarItemIdentifier` →
            // owning Bubo task. Populated for tasks pushed by export so that
            // the reminder we just created doesn't come back as a duplicate
            // import on the next fetch.
            let existingByReminderItemId: [String: BacklogTask] = Dictionary(
                uniqueKeysWithValues: backlogService.tasks.compactMap { task in
                    task.reminderCalendarItemId.map { ($0, task) }
                }
            )
            let activeReminderIds = Set(fetched.map { "reminder_\($0.calendarItemId)" })
            var added = 0

            for item in fetched {
                // Skip reminders that are already tracked by an exported Bubo
                // task — matching on `calendarItemIdentifier` instead of the
                // `reminder_`-prefixed import ID, because the owning task
                // keeps its original Bubo-native ID.
                if existingByReminderItemId[item.calendarItemId] != nil {
                    continue
                }

                let remote = item.task

                if let existing = existingById[remote.id] {
                    // Task is already in the backlog — check whether fields
                    // that Apple Reminders owns have changed externally and
                    // push the update through. Bubo-owned fields (duration,
                    // scheduling, story points, preferred period, status) are
                    // preserved — the user set those locally.
                    //
                    // `silentlyUpdate` bypasses `taskUpdated`; otherwise the
                    // edit-writeback observer would immediately push the same
                    // data back to the reminder we just read from.
                    if let merged = merging(remote: remote, into: existing) {
                        backlogService.silentlyUpdate(merged)
                    }
                    continue
                }

                // New reminder — import unless the user dismissed it earlier.
                if dismissedReminderIds.contains(remote.id) { continue }
                backlogService.addTask(remote)
                added += 1
            }

            // Mirror external completions (and deletions) back into the
            // backlog. Any linked Bubo task still pending/scheduled whose
            // source reminder is no longer in the incomplete fetch must
            // have been finished or removed elsewhere — flip it to done
            // so it stops cluttering the backlog.
            //
            // Covers both directions of the linkage: imported tasks
            // (identified by the `reminder_` prefix) and exported tasks
            // (identified by `reminderCalendarItemId`).
            //
            // `silentlyComplete` bypasses the `taskCompleted` notification
            // so we don't round-trip the write back to Apple Reminders.
            let activeCalendarItemIds = Set(fetched.map(\.calendarItemId))
            let linkedActive = backlogService.tasks.filter { task in
                guard task.status != .done else { return false }
                // Frozen tasks are the user's "set aside" state — don't let an
                // external delete silently complete them. They already skip
                // active sync via this filter.
                guard task.status != .frozen else { return false }
                return task.id.hasPrefix("reminder_") || task.reminderCalendarItemId != nil
            }
            for task in linkedActive {
                let linkedItemId = task.reminderCalendarItemId
                    ?? AppleRemindersService.remindersId(from: task.id)
                guard let linkedItemId else { continue }
                if !activeCalendarItemIds.contains(linkedItemId) {
                    backlogService.silentlyComplete(id: task.id)
                }
            }

            // Prune dismissed IDs whose source reminder is no longer incomplete
            // (the user completed or deleted it in Reminders.app). Keeps the
            // set bounded and lets the task re-import if the reminder is
            // re-opened in Reminders later.
            let stale = dismissedReminderIds.subtracting(activeReminderIds)
            if !stale.isEmpty {
                dismissedReminderIds.subtract(stale)
            }

            importedCount = added
            lastSyncDate = Date()
            isSyncing = false

            if added > 0 {
                NotificationCenter.default.post(name: Self.didImportTasks, object: added)
            }
        }
    }

    // MARK: - External Edit Merging

    /// Applies Apple Reminders-owned fields from `remote` onto `existing`,
    /// preserving Bubo-owned fields (duration, scheduling, story points,
    /// preferred period, dependencies, status).  Returns `nil` when nothing
    /// actually changed — callers use that to skip an unnecessary save.
    private func merging(remote: BacklogTask, into existing: BacklogTask) -> BacklogTask? {
        let titleChanged = existing.title != remote.title
        let priorityChanged = existing.priority != remote.priority
        let deadlineChanged = existing.deadline != remote.deadline
        let contextChanged = existing.context != remote.context
        let notesChanged = existing.notes != remote.notes
        let urlChanged = existing.url != remote.url
        let locationChanged = existing.location != remote.location

        guard titleChanged || priorityChanged || deadlineChanged || contextChanged
            || notesChanged || urlChanged || locationChanged else {
            return nil
        }

        var merged = existing
        merged.title = remote.title
        merged.priority = remote.priority
        merged.deadline = remote.deadline
        merged.context = remote.context
        merged.notes = remote.notes
        merged.url = remote.url
        merged.location = remote.location
        merged.modifiedAt = Date()
        return merged
    }

    // MARK: - Dismissal Tracking

    /// Forget all previously-dismissed reminder IDs so they can be re-imported
    /// on the next sync. Exposed for a "Clear dismissed" button in Settings.
    func clearDismissedReminderIds() {
        dismissedReminderIds.removeAll()
    }

    private func saveDismissedIds() {
        let array = Array(dismissedReminderIds)
        UserDefaults.standard.set(array, forKey: Self.dismissedKey)
    }

    private static func loadDismissedIds() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        return Set(array)
    }

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
            let calendarItemId = try remindersSource.createReminder(
                from: task,
                inListId: settings.remindersExportListId
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
        markSelfWrite()
        do {
            try remindersSource.updateReminderDueDate(
                calendarItemId: calendarItemId,
                date: newDueDate
            )
        } catch {
            logger.error("Failed to push scheduling to Apple Reminders: \(error)")
        }
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
