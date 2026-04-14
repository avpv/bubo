import Foundation
import os

/// Imports tasks from Apple Reminders into the Bubo backlog and optionally
/// writes task completions back to Apple Reminders.
///
/// Design mirrors `ReminderService` for calendar events:
///   - Always instantiated in `App.init`; never does EventKit work on init.
///   - `syncNow()` short-circuits when the feature is disabled or Reminders
///     access hasn't been granted — the popover can always open.
///   - Triggered explicitly from `MenuBarView.onAppear` via `startSync()`,
///     the same pattern as `reminderService.startSync()`.
///
/// Two optional behaviours beyond plain import:
///   - **Dismissal tracking**: when the user removes a reminder-backed task
///     from the Bubo backlog, its ID is remembered so future syncs don't
///     re-import it. The set is pruned when the source reminder is
///     completed / deleted in Apple Reminders.
///   - **Completion writeback**: when the user completes a reminder-backed
///     task in Bubo, the source Apple Reminder is marked done. Off by
///     default — the user opts in via a Settings toggle.
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

            let existingIds = Set(backlogService.tasks.map(\.id))
            let defaultDuration = settings.remindersDefaultDurationMinutes
            var added = 0

            for reminder in reminders {
                let task = AppleRemindersService.shared.toBacklogTask(
                    reminder,
                    defaultDuration: defaultDuration
                )
                // Skip tasks that were already imported, or that the user
                // explicitly removed from the backlog on a previous sync.
                if existingIds.contains(task.id) { continue }
                if dismissedReminderIds.contains(task.id) { continue }
                backlogService.addTask(task)
                added += 1
            }

            // Prune dismissed IDs whose source reminder is no longer incomplete
            // (the user completed or deleted it in Reminders.app). Keeps the
            // set bounded and lets the task re-import if the reminder is
            // re-opened in Reminders later.
            let activeReminderIds = Set(reminders.map { "reminder_\($0.calendarItemIdentifier)" })
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
