import Foundation

/// Bridges Apple Reminders with the Bubo backlog.
///
/// Periodically fetches incomplete reminders from selected lists and
/// imports them as BacklogTasks. Handles deduplication (won't re-import
/// tasks that already exist) and optional two-way completion sync.
@MainActor
@Observable
final class RemindersSyncService {

    /// Posted after a sync that imported new tasks. `object` is the count (Int).
    static let didImportTasks = Notification.Name("BuboRemindersDidImportTasks")

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var syncError: String?
    private(set) var importedCount: Int = 0

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
    private var activeSyncTask: Task<Void, Never>?

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
                self?.syncNow()
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

        // Listen for backlog task removals → remember dismissed IDs
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
    }

    deinit {
        syncTimer?.invalidate()
        for observer in [remindersChangedObserver, taskCompletedObserver, taskRemovedObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
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
            var added = 0

            let defaultDuration = settings.remindersDefaultDurationMinutes

            for reminder in reminders {
                let task = AppleRemindersService.shared.toBacklogTask(reminder, defaultDuration: defaultDuration)
                // Skip tasks that already exist or were explicitly dismissed.
                if !existingIds.contains(task.id) && !dismissedReminderIds.contains(task.id) {
                    backlogService.addTask(task)
                    added += 1
                }
            }

            // Mark backlog tasks as done when their source reminder was
            // completed or deleted externally. Skip the BacklogService
            // notification to avoid a feedback loop (we don't need to
            // write back to Reminders — the change came from there).
            let activeReminderIds = Set(reminders.map { "reminder_\($0.calendarItemIdentifier)" })
            let reminderTasks = backlogService.tasks.filter { $0.id.hasPrefix("reminder_") && $0.status != .done }
            for task in reminderTasks {
                if !activeReminderIds.contains(task.id) && !dismissedReminderIds.contains(task.id) {
                    backlogService.silentlyComplete(id: task.id)
                }
            }

            // Prune dismissed IDs — remove entries for reminders that no
            // longer appear as incomplete (completed or deleted in Reminders).
            // This prevents the set from growing unboundedly.
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

    // MARK: - Two-Way Completion

    /// Called when the user completes a task in Bubo. If it originated from
    /// Apple Reminders and two-way sync is enabled, marks it done there too.
    private func handleTaskCompleted(taskId: String) {
        guard settings.remindersCompletionSync,
              let calendarItemId = AppleRemindersService.remindersId(from: taskId) else {
            return
        }

        do {
            try AppleRemindersService.shared.completeReminder(calendarItemId: calendarItemId)
        } catch {
            print("Failed to complete reminder in Apple Reminders: \(error)")
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
