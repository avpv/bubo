import Foundation
import os

/// Bridges Apple Reminders with the Bubo backlog — full two-way sync.
///
/// **Import** (Reminders → Bubo): Periodically fetches incomplete reminders
/// from selected lists and imports them as BacklogTasks. Updates existing
/// imported tasks when their source reminder was edited. Uses `modifiedAt`
/// / `lastModifiedDate` timestamps for conflict resolution.
///
/// **Export** (Bubo → Reminders): When enabled, pushes Bubo-native tasks to
/// a designated Reminders list so they appear on all iCloud-connected devices
/// (iPhone, iPad, etc.). Handles real-time push on task creation/update and
/// (optionally) deletion.
///
/// **Feedback loop protection**: A write to EventKit triggers an async
/// `EKEventStoreChanged` notification ~100ms later. We use a timestamp
/// (`suppressRemoteChangesUntil`) rather than a boolean flag so that
/// late-arriving notifications from our own writes don't kick off a re-sync.
private let logger = Logger(subsystem: "com.avpv.Bubo", category: "RemindersSyncService")

@MainActor
@Observable
final class RemindersSyncService {

    /// Posted after a sync that imported new tasks. `object` is the count (Int).
    static let didImportTasks = Notification.Name("BuboRemindersDidImportTasks")
    /// Posted after a sync that exported tasks. `object` is the count (Int).
    static let didExportTasks = Notification.Name("BuboRemindersDidExportTasks")

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var syncError: String?
    private(set) var importedCount: Int = 0
    private(set) var exportedCount: Int = 0

    private var settings: ReminderSettings
    private var backlogService: BacklogService

    /// IDs of reminder-sourced tasks the user explicitly removed from the
    /// backlog. Prevents re-import on the next sync cycle.
    private var dismissedReminderIds: Set<String> {
        didSet { saveDismissedIds() }
    }
    private static let dismissedKey = "BuboDismissedReminderIds"
    private nonisolated(unsafe) var syncTimer: Timer?
    private nonisolated(unsafe) var remindersChangedObserver: Any?
    private nonisolated(unsafe) var taskCompletedObserver: Any?
    private nonisolated(unsafe) var taskRemovedObserver: Any?
    private nonisolated(unsafe) var taskAddedObserver: Any?
    private nonisolated(unsafe) var taskUpdatedObserver: Any?
    private var activeSyncTask: Task<Void, Never>?

    /// Until this timestamp, ignore `remindersDataChanged` notifications —
    /// they're almost certainly echoes of our own writes. Set 2 seconds into
    /// the future whenever we call a write method on EventKit.
    private var suppressRemoteChangesUntil: Date = .distantPast
    private static let selfWriteSuppressionInterval: TimeInterval = 2.0

    init(settings: ReminderSettings, backlogService: BacklogService) {
        self.settings = settings
        self.backlogService = backlogService
        self.dismissedReminderIds = Self.loadDismissedIds()

        // Listen for external changes in Reminders.app / iCloud sync
        remindersChangedObserver = NotificationCenter.default.addObserver(
            forName: AppleRemindersService.remindersDataChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Drop notifications caused by our own writes.
                if Date() < self.suppressRemoteChangesUntil { return }
                self.syncNow()
            }
        }

        // Listen for backlog task completions → two-way sync to Reminders
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

        // Listen for backlog task removals → dismissed IDs + optional deletion
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

        // Listen for new tasks → export to Reminders immediately
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

        // Listen for task updates → push changes to Reminders
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
    }

    deinit {
        syncTimer?.invalidate()
        let observers = [
            remindersChangedObserver, taskCompletedObserver, taskRemovedObserver,
            taskAddedObserver, taskUpdatedObserver
        ].compactMap { $0 }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Self-Write Suppression

    /// Call this immediately before writing to EventKit so the resulting
    /// `EKEventStoreChanged` notification doesn't trigger a re-sync.
    private func markSelfWrite() {
        suppressRemoteChangesUntil = Date().addingTimeInterval(Self.selfWriteSuppressionInterval)
    }

    // MARK: - Sync Timer

    /// Start a repeating sync on the same interval as calendar sync.
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

    // MARK: - Full Sync

    func syncNow() {
        guard settings.isRemindersSyncEnabled else {
            syncError = nil
            return
        }

        guard AppleRemindersService.hasAccess else {
            syncError = "Reminders access not granted"
            return
        }

        // Prevent concurrent syncs — cancel any in-flight fetch.
        activeSyncTask?.cancel()

        isSyncing = true
        syncError = nil

        activeSyncTask = Task {
            // ── Phase 1: Import (Reminders → Bubo) ──
            let reminders = await AppleRemindersService.shared.fetchIncompleteReminders(
                fromListIds: settings.selectedRemindersListIds
            )
            guard !Task.isCancelled else { return }

            let existingIds = Set(backlogService.tasks.map(\.id))
            var added = 0

            let defaultDuration = settings.remindersDefaultDurationMinutes

            for reminder in reminders {
                let freshTask = AppleRemindersService.shared.toBacklogTask(
                    reminder, defaultDuration: defaultDuration
                )

                if existingIds.contains(freshTask.id) {
                    // Task already exists — apply conflict resolution.
                    applyRemoteChangesIfNewer(
                        freshTask: freshTask,
                        reminderModified: reminder.lastModifiedDate
                    )
                } else if !dismissedReminderIds.contains(freshTask.id) {
                    backlogService.addTask(freshTask)
                    added += 1
                }
            }

            // Mark backlog tasks as done when their source reminder was
            // completed or deleted externally. `silentlyComplete` doesn't
            // post `taskCompleted`, so no feedback loop.
            let activeReminderIds = Set(reminders.map { "reminder_\($0.calendarItemIdentifier)" })
            let reminderTasks = backlogService.tasks.filter {
                $0.id.hasPrefix("reminder_") && $0.status != .done
            }
            for task in reminderTasks {
                if !activeReminderIds.contains(task.id) && !dismissedReminderIds.contains(task.id) {
                    backlogService.silentlyComplete(id: task.id)
                }
            }

            // Prune dismissed IDs — remove entries for reminders that no
            // longer appear as incomplete (completed or deleted in Reminders).
            let stale = dismissedReminderIds.subtracting(activeReminderIds)
            if !stale.isEmpty {
                dismissedReminderIds.subtract(stale)
            }

            // ── Phase 2: Export (Bubo → Reminders) ──
            var exported = 0
            if settings.remindersExportEnabled {
                exported = exportBuboTasksToReminders()
            }

            importedCount = added
            exportedCount = exported
            lastSyncDate = Date()
            isSyncing = false

            if added > 0 {
                NotificationCenter.default.post(name: Self.didImportTasks, object: added)
            }
            if exported > 0 {
                NotificationCenter.default.post(name: Self.didExportTasks, object: exported)
            }
        }
    }

    // MARK: - Import: Conflict Resolution

    /// Updates an already-imported task's fields only if the source reminder
    /// was modified more recently than our local copy. Uses `silentlyUpdate`
    /// so the resulting write doesn't bounce back to Reminders.
    private func applyRemoteChangesIfNewer(freshTask: BacklogTask, reminderModified: Date?) {
        guard let index = backlogService.tasks.firstIndex(where: { $0.id == freshTask.id }) else { return }
        let existing = backlogService.tasks[index]

        // Compare only the fields that can round-trip through Apple Reminders.
        let fieldsChanged = existing.title != freshTask.title
            || existing.priority != freshTask.priority
            || existing.deadline != freshTask.deadline
            || existing.context != freshTask.context
        guard fieldsChanged else { return }

        // Conflict resolution: only overwrite local state if the remote
        // reminder is strictly newer. If we have no timestamps, fall through
        // and accept the remote version (first-sync case).
        if let localMod = existing.modifiedAt, let remoteMod = reminderModified,
           localMod > remoteMod {
            // Local changes are newer — push them back to Reminders instead.
            if let calendarItemId = AppleRemindersService.remindersId(from: existing.id) {
                markSelfWrite()
                do {
                    try AppleRemindersService.shared.updateReminder(
                        calendarItemId: calendarItemId, from: existing
                    )
                } catch {
                    logger.error("Failed to push local changes to reminder: \(error)")
                }
            }
            return
        }

        // Remote is newer (or ties) — adopt remote values.
        var updated = existing
        updated.title = freshTask.title
        updated.priority = freshTask.priority
        updated.deadline = freshTask.deadline
        updated.context = freshTask.context
        backlogService.silentlyUpdate(updated)
    }

    // MARK: - Export: Push Bubo Tasks → Apple Reminders

    /// Iterates all non-reminder Bubo tasks and creates reminders for any
    /// that don't yet have a `reminderCalendarItemId`. Also pushes updates
    /// for already-linked tasks whose fields drifted. Uses `updateReminder`'s
    /// built-in change detection to skip no-op writes.
    private func exportBuboTasksToReminders() -> Int {
        let listId = settings.remindersExportListId
        var createdCount = 0

        for task in backlogService.tasks {
            // Skip tasks that came from Reminders (already exist there)
            guard !task.id.hasPrefix("reminder_") else { continue }

            if task.reminderCalendarItemId == nil {
                // Not yet exported — create a new reminder. Skip completed
                // tasks (no reason to export done work).
                guard task.status != .done else { continue }

                markSelfWrite()
                do {
                    let calendarItemId = try AppleRemindersService.shared.createReminder(
                        from: task, inListId: listId
                    )
                    backlogService.silentlyUpdateReminderMapping(
                        taskId: task.id, reminderCalendarItemId: calendarItemId
                    )
                    createdCount += 1
                } catch {
                    logger.error("Failed to export task '\(task.title)' to Reminders: \(error)")
                }
            } else if let calendarItemId = task.reminderCalendarItemId {
                // Already linked — push any changes (no-op if identical).
                markSelfWrite()
                do {
                    try AppleRemindersService.shared.updateReminder(
                        calendarItemId: calendarItemId, from: task
                    )
                } catch {
                    logger.error("Failed to update exported reminder for '\(task.title)': \(error)")
                }
            }
        }

        return createdCount
    }

    // MARK: - Real-Time Export: Task Added

    /// Called when a new task is created in Bubo. If export is enabled and
    /// the task didn't originate from Reminders, push it immediately.
    private func handleTaskAdded(taskId: String) {
        guard settings.isRemindersSyncEnabled,
              settings.remindersExportEnabled,
              AppleRemindersService.hasAccess,
              !taskId.hasPrefix("reminder_") else { return }

        guard let task = backlogService.tasks.first(where: { $0.id == taskId }),
              task.reminderCalendarItemId == nil else { return }

        markSelfWrite()
        do {
            let calendarItemId = try AppleRemindersService.shared.createReminder(
                from: task, inListId: settings.remindersExportListId
            )
            // Silent update — does NOT post taskUpdated, so no re-sync.
            backlogService.silentlyUpdateReminderMapping(
                taskId: task.id, reminderCalendarItemId: calendarItemId
            )
            logger.info("Exported new task '\(task.title)' to Reminders")
        } catch {
            logger.error("Failed to export new task '\(task.title)' to Reminders: \(error)")
        }
    }

    // MARK: - Real-Time Export: Task Updated

    /// Called when a task is updated in Bubo. Pushes changes to the
    /// linked reminder if one exists. Skips no-op updates.
    private func handleTaskUpdated(taskId: String) {
        guard settings.isRemindersSyncEnabled,
              AppleRemindersService.hasAccess else { return }

        guard let task = backlogService.tasks.first(where: { $0.id == taskId }) else { return }

        let targetId: String?
        if let remindersId = AppleRemindersService.remindersId(from: taskId) {
            // Imported reminder — always keep the source in sync.
            targetId = remindersId
        } else if settings.remindersExportEnabled, let itemId = task.reminderCalendarItemId {
            // Exported Bubo-native task — only if export is enabled.
            targetId = itemId
        } else {
            targetId = nil
        }

        guard let calendarItemId = targetId else { return }

        markSelfWrite()
        do {
            let didWrite = try AppleRemindersService.shared.updateReminder(
                calendarItemId: calendarItemId, from: task
            )
            if didWrite {
                logger.debug("Pushed update for '\(task.title)' to Reminders")
            }
        } catch {
            logger.error("Failed to update reminder for '\(task.title)': \(error)")
        }
    }

    // MARK: - Real-Time Delete: Task Removed

    /// Called when a task is removed in Bubo. For imported reminder tasks we
    /// remember the dismissal so we don't re-import on next sync. For tasks
    /// with a linked reminder we optionally delete the reminder too (opt-in
    /// via `remindersDeletionSync`).
    private func handleTaskRemoved(_ removed: BacklogTask) {
        // Imported reminder tasks: always track dismissal to prevent re-import.
        if removed.id.hasPrefix("reminder_") {
            dismissedReminderIds.insert(removed.id)

            // If the user has opted into deletion sync, also delete the
            // source reminder on iOS/iCloud.
            if settings.remindersDeletionSync,
               let calendarItemId = AppleRemindersService.remindersId(from: removed.id) {
                deleteReminderSilently(calendarItemId: calendarItemId)
            }
            return
        }

        // Bubo-native task with a linked exported reminder: optionally delete.
        if settings.remindersDeletionSync,
           let calendarItemId = removed.reminderCalendarItemId {
            deleteReminderSilently(calendarItemId: calendarItemId)
        }
    }

    /// Deletes a reminder and logs errors. Uses self-write suppression so
    /// the resulting EKEventStoreChanged notification doesn't trigger a sync.
    private func deleteReminderSilently(calendarItemId: String) {
        markSelfWrite()
        do {
            try AppleRemindersService.shared.deleteReminder(calendarItemId: calendarItemId)
        } catch {
            logger.error("Failed to delete reminder \(calendarItemId): \(error)")
        }
    }

    // MARK: - Two-Way Completion

    /// Called when the user completes a task in Bubo. If it originated from
    /// Apple Reminders and two-way sync is enabled, marks it done there too.
    /// Also handles completion of exported Bubo-native tasks.
    private func handleTaskCompleted(taskId: String) {
        guard settings.remindersCompletionSync else { return }

        let calendarItemId: String?
        if let remindersId = AppleRemindersService.remindersId(from: taskId) {
            calendarItemId = remindersId
        } else if let task = backlogService.tasks.first(where: { $0.id == taskId }),
                  let itemId = task.reminderCalendarItemId {
            calendarItemId = itemId
        } else {
            calendarItemId = nil
        }

        guard let id = calendarItemId else { return }

        markSelfWrite()
        do {
            try AppleRemindersService.shared.completeReminder(calendarItemId: id)
        } catch {
            logger.error("Failed to complete reminder in Apple Reminders: \(error)")
        }
    }

    // MARK: - Dismissed IDs Persistence

    private func saveDismissedIds() {
        let array = Array(dismissedReminderIds)
        UserDefaults.standard.set(array, forKey: Self.dismissedKey)
        CloudSyncService.shared.push(Self.dismissedKey)
    }

    private static func loadDismissedIds() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        return Set(array)
    }
}
