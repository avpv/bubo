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
///   - **External completion mirroring** (Reminders → Bubo): when a
///     reminder-backed task exists in Bubo but its source reminder is no
///     longer incomplete (user finished or deleted it in Reminders.app or
///     on another device), the Bubo task is silently marked done.
///   - **Dismissal tracking**: when the user removes a reminder-backed
///     task from the Bubo backlog, its ID is remembered so future syncs
///     don't re-import it. The set is pruned when the source reminder is
///     completed / deleted in Apple Reminders.
///   - **Completion writeback** (Bubo → Reminders): when the user
///     completes a reminder-backed task in Bubo, the source Apple
///     Reminder is marked done. Off by default — the user opts in via a
///     Settings toggle.
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

    private nonisolated(unsafe) var syncTimer: Timer?
    private nonisolated(unsafe) var remindersChangedObserver: Any?
    private nonisolated(unsafe) var taskRemovedObserver: Any?
    private nonisolated(unsafe) var taskCompletedObserver: Any?
    private var activeSyncTask: Task<Void, Never>?

    private static let dismissedKey = "BuboDismissedReminderIds"

    init(settings: ReminderSettings, backlogService: BacklogService) {
        self.settings = settings
        self.backlogService = backlogService
        self.dismissedReminderIds = Self.loadDismissedIds()

        // Listen for external changes (user edits Reminders.app, iCloud sync).
        // The callback short-circuits via `syncNow()` when the feature is off,
        // so this observer is cheap even for users who never enable the sync.
        remindersChangedObserver = NotificationCenter.default.addObserver(
            forName: AppleRemindersService.remindersDataChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncNow()
            }
        }

        // Remember reminder-backed tasks the user removes, so we don't keep
        // re-importing them. Non-reminder IDs are ignored.
        taskRemovedObserver = NotificationCenter.default.addObserver(
            forName: BacklogService.taskRemoved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let taskId = notification.object as? String,
                  taskId.hasPrefix("reminder_") else { return }
            Task { @MainActor in
                self?.dismissedReminderIds.insert(taskId)
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
    }

    deinit {
        syncTimer?.invalidate()
        let observers = [
            remindersChangedObserver, taskRemovedObserver, taskCompletedObserver,
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

        guard AppleRemindersService.hasAccess else {
            syncError = "Reminders access not granted"
            return
        }

        // Prevent concurrent syncs — cancel any in-flight fetch.
        activeSyncTask?.cancel()

        isSyncing = true
        syncError = nil

        activeSyncTask = Task {
            let reminders = await AppleRemindersService.shared.fetchIncompleteReminders(
                fromListIds: settings.selectedRemindersListIds
            )
            guard !Task.isCancelled else { return }

            let existingById = Dictionary(
                uniqueKeysWithValues: backlogService.tasks.map { ($0.id, $0) }
            )
            let defaultDuration = settings.remindersDefaultDurationMinutes
            let activeReminderIds = Set(reminders.map { "reminder_\($0.calendarItemIdentifier)" })
            var added = 0

            for reminder in reminders {
                let remote = AppleRemindersService.shared.toBacklogTask(
                    reminder,
                    defaultDuration: defaultDuration
                )

                if let existing = existingById[remote.id] {
                    // Task is already in the backlog — check whether fields
                    // that Apple Reminders owns have changed externally and
                    // push the update through. Bubo-owned fields (duration,
                    // scheduling, story points, preferred period, status) are
                    // preserved — the user set those locally.
                    if let merged = merging(remote: remote, into: existing) {
                        backlogService.updateTask(merged)
                    }
                    continue
                }

                // New reminder — import unless the user dismissed it earlier.
                if dismissedReminderIds.contains(remote.id) { continue }
                backlogService.addTask(remote)
                added += 1
            }

            // Mirror external completions (and deletions) back into the
            // backlog. Any reminder-backed task still pending/scheduled in
            // Bubo whose source reminder is no longer in the incomplete
            // fetch must have been finished or removed elsewhere — flip it
            // to done so it stops cluttering the backlog.
            //
            // `silentlyComplete` bypasses the `taskCompleted` notification
            // so we don't round-trip the write back to Apple Reminders.
            let reminderBackedActive = backlogService.tasks.filter { task in
                task.id.hasPrefix("reminder_") && task.status != .done
            }
            for task in reminderBackedActive where !activeReminderIds.contains(task.id) {
                backlogService.silentlyComplete(id: task.id)
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

        guard titleChanged || priorityChanged || deadlineChanged || contextChanged else {
            return nil
        }

        var merged = existing
        merged.title = remote.title
        merged.priority = remote.priority
        merged.deadline = remote.deadline
        merged.context = remote.context
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

    /// Called when the user marks a task done in Bubo. If the task originated
    /// from Apple Reminders and the user opted into completion writeback,
    /// marks the source reminder done too.
    private func handleTaskCompleted(taskId: String) {
        guard settings.remindersCompletionSync,
              let calendarItemId = AppleRemindersService.remindersId(from: taskId) else {
            return
        }

        do {
            try AppleRemindersService.shared.completeReminder(calendarItemId: calendarItemId)
        } catch {
            logger.error("Failed to complete reminder in Apple Reminders: \(error)")
        }
    }
}
