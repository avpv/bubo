import Foundation

/// Bridges Apple Reminders with the Bubo backlog.
///
/// Periodically fetches incomplete reminders from selected lists and
/// imports them as BacklogTasks. Handles deduplication (won't re-import
/// tasks that already exist) and optional two-way completion sync.
@MainActor
@Observable
final class RemindersSyncService {

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var syncError: String?
    private(set) var importedCount: Int = 0

    private var settings: ReminderSettings
    private var backlogService: BacklogService
    private nonisolated(unsafe) var syncTimer: Timer?
    private nonisolated(unsafe) var remindersChangedObserver: Any?
    private nonisolated(unsafe) var taskCompletedObserver: Any?

    init(settings: ReminderSettings, backlogService: BacklogService) {
        self.settings = settings
        self.backlogService = backlogService

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
    }

    deinit {
        syncTimer?.invalidate()
        if let observer = remindersChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = taskCompletedObserver {
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

        isSyncing = true
        syncError = nil

        Task {
            let reminders = await AppleRemindersService.shared.fetchIncompleteReminders(
                fromListIds: settings.selectedRemindersListIds
            )

            let existingIds = Set(backlogService.tasks.map(\.id))
            var added = 0

            for reminder in reminders {
                let task = AppleRemindersService.shared.toBacklogTask(reminder)
                if !existingIds.contains(task.id) {
                    backlogService.addTask(task)
                    added += 1
                }
            }

            // Remove backlog tasks whose source reminder was completed externally
            let activeReminderIds = Set(reminders.map { "reminder_\($0.calendarItemIdentifier)" })
            let reminderTasks = backlogService.tasks.filter { $0.id.hasPrefix("reminder_") && $0.status != .done }
            for task in reminderTasks {
                if !activeReminderIds.contains(task.id) {
                    // The reminder no longer appears as incomplete — it was
                    // completed or deleted in Reminders.app. Mark it done.
                    backlogService.completeTask(id: task.id)
                }
            }

            importedCount = added
            lastSyncDate = Date()
            isSyncing = false
        }
    }

    // MARK: - Two-Way Completion

    /// Call this when a Bubo task is completed. If it originated from Apple
    /// Reminders and two-way sync is enabled, marks it done there too.
    func handleTaskCompleted(taskId: String) {
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
}
