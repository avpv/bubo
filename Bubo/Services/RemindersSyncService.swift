import Foundation
import os

/// Bridges Apple Reminders with the Bubo backlog — full two-way sync.
///
/// **Import** (Reminders → Bubo): Periodically fetches incomplete reminders
/// from selected lists and imports them as BacklogTasks. Updates existing
/// imported tasks when their source reminder changes.
///
/// **Export** (Bubo → Reminders): When enabled, pushes Bubo-native tasks to
/// a designated Reminders list so they appear on all iCloud-connected devices
/// (iPhone, iPad, etc.). Handles real-time push on task creation/update.
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

    /// Guard against feedback loops: set while we're pushing changes to
    /// Reminders so that the EKEventStore change notification doesn't
    /// trigger a re-sync immediately.
    private var isExporting = false

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
                guard self?.isExporting != true else { return }
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
                let task = AppleRemindersService.shared.toBacklogTask(reminder, defaultDuration: defaultDuration)

                if existingIds.contains(task.id) {
                    // Task already exists — update fields if the reminder changed
                    updateImportedTaskIfNeeded(task)
                } else if !dismissedReminderIds.contains(task.id) {
                    // New task — import it
                    backlogService.addTask(task)
                    added += 1
                }
            }

            // Mark backlog tasks as done when their source reminder was
            // completed or deleted externally. Skip the BacklogService
            // notification to avoid a feedback loop.
            let activeReminderIds = Set(reminders.map { "reminder_\($0.calendarItemIdentifier)" })
            let reminderTasks = backlogService.tasks.filter { $0.id.hasPrefix("reminder_") && $0.status != .done }
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

    // MARK: - Import: Update Existing Tasks

    /// Updates an already-imported task's fields if the source reminder changed
    /// (e.g. title or due date edited on iPhone).
    private func updateImportedTaskIfNeeded(_ freshTask: BacklogTask) {
        guard let index = backlogService.tasks.firstIndex(where: { $0.id == freshTask.id }) else { return }
        let existing = backlogService.tasks[index]

        // Only update if something meaningful changed
        guard existing.title != freshTask.title
                || existing.priority != freshTask.priority
                || existing.deadline != freshTask.deadline
                || existing.context != freshTask.context else {
            return
        }

        var updated = existing
        updated.title = freshTask.title
        updated.priority = freshTask.priority
        updated.deadline = freshTask.deadline
        updated.context = freshTask.context
        backlogService.updateTask(updated)
    }

    // MARK: - Export: Push Bubo Tasks → Apple Reminders

    /// Iterates all non-reminder Bubo tasks and creates reminders for any
    /// that don't yet have a `reminderCalendarItemId`.
    /// Returns the number of newly exported tasks.
    private func exportBuboTasksToReminders() -> Int {
        let listId = settings.remindersExportListId
        var count = 0

        isExporting = true
        defer { isExporting = false }

        for task in backlogService.tasks {
            // Skip tasks that came from Reminders (already exist there)
            guard !task.id.hasPrefix("reminder_") else { continue }
            // Skip tasks that already have a linked reminder
            guard task.reminderCalendarItemId == nil else {
                // Update existing reminder if task was modified
                updateExportedReminderIfNeeded(task)
                continue
            }
            // Skip completed tasks — no need to export done tasks
            guard task.status != .done else { continue }

            do {
                let calendarItemId = try AppleRemindersService.shared.createReminder(
                    from: task, inListId: listId
                )
                // Store the mapping back on the task
                var updated = task
                updated.reminderCalendarItemId = calendarItemId
                backlogService.updateTask(updated)
                count += 1
            } catch {
                logger.error("Failed to export task '\(task.title)' to Reminders: \(error)")
            }
        }

        return count
    }

    /// Updates the exported reminder to match current Bubo task state.
    private func updateExportedReminderIfNeeded(_ task: BacklogTask) {
        guard let calendarItemId = task.reminderCalendarItemId else { return }

        isExporting = true
        defer { isExporting = false }

        do {
            try AppleRemindersService.shared.updateReminder(
                calendarItemId: calendarItemId, from: task
            )
        } catch {
            logger.error("Failed to update exported reminder for '\(task.title)': \(error)")
        }
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

        isExporting = true
        defer { isExporting = false }

        do {
            let calendarItemId = try AppleRemindersService.shared.createReminder(
                from: task, inListId: settings.remindersExportListId
            )
            var updated = task
            updated.reminderCalendarItemId = calendarItemId
            backlogService.updateTask(updated)
            logger.info("Exported new task '\(task.title)' to Reminders")
        } catch {
            logger.error("Failed to export new task '\(task.title)' to Reminders: \(error)")
        }
    }

    // MARK: - Real-Time Export: Task Updated

    /// Called when a task is updated in Bubo. Pushes changes to the
    /// linked reminder if one exists.
    private func handleTaskUpdated(taskId: String) {
        guard settings.isRemindersSyncEnabled,
              settings.remindersExportEnabled,
              AppleRemindersService.hasAccess else { return }

        guard let task = backlogService.tasks.first(where: { $0.id == taskId }) else { return }

        // For imported reminder tasks, update the source reminder
        if let remindersId = AppleRemindersService.remindersId(from: taskId) {
            isExporting = true
            defer { isExporting = false }
            do {
                try AppleRemindersService.shared.updateReminder(
                    calendarItemId: remindersId, from: task
                )
            } catch {
                logger.error("Failed to update source reminder for '\(task.title)': \(error)")
            }
            return
        }

        // For Bubo-native tasks with a linked reminder, update it
        if let calendarItemId = task.reminderCalendarItemId {
            isExporting = true
            defer { isExporting = false }
            do {
                try AppleRemindersService.shared.updateReminder(
                    calendarItemId: calendarItemId, from: task
                )
            } catch {
                logger.error("Failed to update exported reminder for '\(task.title)': \(error)")
            }
        }
    }

    // MARK: - Two-Way Completion

    /// Called when the user completes a task in Bubo. If it originated from
    /// Apple Reminders and two-way sync is enabled, marks it done there too.
    /// Also handles completion of exported Bubo-native tasks.
    private func handleTaskCompleted(taskId: String) {
        guard settings.remindersCompletionSync else { return }

        isExporting = true
        defer { isExporting = false }

        // Imported reminder task
        if let calendarItemId = AppleRemindersService.remindersId(from: taskId) {
            do {
                try AppleRemindersService.shared.completeReminder(calendarItemId: calendarItemId)
            } catch {
                logger.error("Failed to complete reminder in Apple Reminders: \(error)")
            }
            return
        }

        // Bubo-native task with exported reminder
        if let task = backlogService.tasks.first(where: { $0.id == taskId }),
           let calendarItemId = task.reminderCalendarItemId {
            do {
                try AppleRemindersService.shared.completeReminder(calendarItemId: calendarItemId)
            } catch {
                logger.error("Failed to complete exported reminder: \(error)")
            }
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
