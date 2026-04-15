import Foundation
import SwiftData

// MARK: - Backlog Service

/// Manages persistent task backlog. Tasks live here until completed —
/// never consumed by optimization, automatically carried over across days.
@MainActor
@Observable
final class BacklogService {

    /// Posted when a task is marked done. `object` is the task ID (String).
    static let taskCompleted = Notification.Name("BuboBacklogTaskCompleted")

    /// Posted when a task is removed. `object` is the removed `BacklogTask`
    /// — downstream observers need fields like `reminderCalendarItemId` that
    /// can't be looked up after the task is already gone from the array.
    static let taskRemoved = Notification.Name("BuboBacklogTaskRemoved")

    /// Posted when a new task is added. `object` is the task ID (String).
    /// Used by `RemindersSyncService` to push Bubo-native tasks out to
    /// Apple Reminders when the user opted into export.
    static let taskAdded = Notification.Name("BuboBacklogTaskAdded")

    /// Posted when a task is updated via `updateTask`. `object` is the task
    /// ID (String). Bypassed by `silentlyUpdate` for sync-driven merges so
    /// we don't echo remote edits straight back to their source.
    static let taskUpdated = Notification.Name("BuboBacklogTaskUpdated")

    /// Posted when a task's schedule changes via `markScheduled` /
    /// `unschedule`. `object` is the task ID (String). Lets
    /// `RemindersSyncService` push the new due date back to Apple Reminders.
    static let taskScheduleChanged = Notification.Name("BuboBacklogTaskScheduleChanged")

    private(set) var tasks: [BacklogTask] = []
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        loadTasks()
    }

    // MARK: - Queries

    /// Tasks that need scheduling (not done, not yet placed).
    var pending: [BacklogTask] {
        tasks.filter { $0.status == .pending }
    }

    /// All tasks available for (re)scheduling — pending and already-scheduled.
    var schedulable: [BacklogTask] {
        tasks.filter { $0.status != .done }
    }

    /// Tasks that have been placed in the schedule.
    var scheduled: [BacklogTask] {
        tasks.filter { $0.status == .scheduled }
    }

    /// Completed tasks.
    var done: [BacklogTask] {
        tasks.filter { $0.status == .done }
    }

    /// Tasks pending for more than 14 days
    var staleTasks: [BacklogTask] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        return tasks.filter { task in
            task.status == .pending && task.createdAt <= cutoff
        }
    }

    /// Overdue tasks — were scheduled for a past date but not completed.
    var overdue: [BacklogTask] {
        let today = Calendar.current.startOfDay(for: Date())
        return tasks.filter { task in
            task.status == .scheduled
                && task.scheduledDate != nil
                && task.scheduledDate! < today
        }
    }

    /// Tasks grouped by context/project for display.
    ///
    /// Order inside each group is the user-controlled storage order — reorderTask
    /// mutates `tasks`, so dragging a row to a new position takes effect here.
    /// Urgency is still surfaced via the "N urgent" badge in the header and the
    /// red "!" marker on rows; we don't force-sort by deadline, because that
    /// would silently override whatever sequence the user dragged into place.
    var groupedByContext: [(context: String?, tasks: [BacklogTask])] {
        let active = tasks.filter { $0.status != .done }
        var groups: [(context: String?, tasks: [BacklogTask])] = []
        var indexByContext: [String?: Int] = [:]
        for task in active {
            if let existing = indexByContext[task.context] {
                groups[existing].tasks.append(task)
            } else {
                indexByContext[task.context] = groups.count
                groups.append((context: task.context, tasks: [task]))
            }
        }
        // Stable: keep first-seen order, but push the "no context" bucket last
        // so tagged groups don't get visually fragmented by untagged tasks.
        groups.sort { lhs, rhs in
            switch (lhs.context, rhs.context) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            default: return false
            }
        }
        return groups
    }

    /// Urgent tasks — deadline within N days.
    func urgent(withinDays days: Int = 2) -> [BacklogTask] {
        let cutoff = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return tasks.filter { task in
            task.status != .done
                && task.deadline != nil
                && task.deadline! <= cutoff
        }
    }

    // MARK: - Mutations

    func addTask(_ task: BacklogTask) {
        tasks.append(task)
        saveTasks()
        NotificationCenter.default.post(name: Self.taskAdded, object: task.id)
    }

    func addTasks(_ newTasks: [BacklogTask]) {
        tasks.append(contentsOf: newTasks)
        saveTasks()
        for task in newTasks {
            NotificationCenter.default.post(name: Self.taskAdded, object: task.id)
        }
    }

    func updateTask(_ task: BacklogTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
        saveTasks()
        NotificationCenter.default.post(name: Self.taskUpdated, object: task.id)
    }

    /// Update without posting `taskUpdated`. Used by `RemindersSyncService`
    /// when merging fields it just read from Apple Reminders — posting
    /// `taskUpdated` there would cause the writeback observer to push the
    /// same data straight back to the reminder we read from.
    func silentlyUpdate(_ task: BacklogTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
        saveTasks()
    }

    func removeTask(id: String) -> BacklogTask? {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = tasks.remove(at: index)
        saveTasks()
        // Post the full task so observers can inspect fields like
        // `reminderCalendarItemId` for cleanup of external state — the task
        // is already gone from `tasks` by the time they receive this.
        NotificationCenter.default.post(name: Self.taskRemoved, object: removed)
        return removed
    }

    func completeTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .done
        tasks[index].completedAt = Date()
        saveTasks()
        NotificationCenter.default.post(name: Self.taskCompleted, object: id)
    }

    /// Mark a task done without posting `taskCompleted`.
    ///
    /// Used by `RemindersSyncService` when it learns that a reminder was
    /// completed externally (in Reminders.app or on another device). Posting
    /// `taskCompleted` from that code path would round-trip the write back
    /// to Apple Reminders, which is pointless — the reminder is already done.
    func silentlyComplete(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .done
        tasks[index].completedAt = Date()
        saveTasks()
    }

    /// Store the Apple Reminders `calendarItemIdentifier` for a Bubo-native
    /// task without firing any notifications. Used by `RemindersSyncService`
    /// right after creating the linked reminder — we need to remember the ID
    /// so future syncs dedupe correctly, but any notification here would
    /// kick off another export attempt.
    func silentlyUpdateReminderMapping(taskId: String, calendarItemId: String?) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[index].reminderCalendarItemId = calendarItemId
        saveTasks()
    }

    func markScheduled(id: String, eventId: String, date: Date) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .scheduled
        tasks[index].scheduledEventId = eventId
        tasks[index].scheduledDate = date
        saveTasks()
        NotificationCenter.default.post(name: Self.taskScheduleChanged, object: id)
    }

    func unschedule(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .pending
        tasks[index].scheduledEventId = nil
        tasks[index].scheduledDate = nil
        saveTasks()
        NotificationCenter.default.post(name: Self.taskScheduleChanged, object: id)
    }

    /// Re-insert a previously removed task (for undo).
    /// When `index` is provided we try to put the task back where it was so
    /// the user-controlled order survives the delete/undo round-trip; falls
    /// back to appending if the index is out of range or nil.
    func restoreTask(_ task: BacklogTask, at index: Int? = nil) {
        if let index, index >= 0, index <= tasks.count {
            tasks.insert(task, at: index)
        } else {
            tasks.append(task)
        }
        saveTasks()
    }

    /// Current global index of a task by ID, or nil if it's not in the list.
    /// Callers capture this before `removeTask` so undo can restore position.
    func indexOfTask(id: String) -> Int? {
        tasks.firstIndex(where: { $0.id == id })
    }

    /// Move tasks that were scheduled in the past but not completed back to pending.
    func carryOverUnfinished() {
        let today = Calendar.current.startOfDay(for: Date())
        var changed = false
        for i in tasks.indices {
            if tasks[i].status == .scheduled,
               let scheduled = tasks[i].scheduledDate,
               scheduled < today {
                tasks[i].status = .pending
                tasks[i].scheduledEventId = nil
                tasks[i].scheduledDate = nil
                changed = true
            }
        }
        if changed { saveTasks() }
    }

    func reorderTask(from: Int, to: Int) {
        let active = tasks.filter { $0.status != .done }
        guard from < active.count, to < active.count else { return }
        let movedId = active[from].id
        let targetId = active[to].id
        guard let fromGlobal = tasks.firstIndex(where: { $0.id == movedId }),
              let toGlobal = tasks.firstIndex(where: { $0.id == targetId }) else { return }
        let task = tasks.remove(at: fromGlobal)
        tasks.insert(task, at: toGlobal)
        saveTasks()
    }

    /// Move `moved` so it sits directly before `target` in the storage order.
    /// No-op if either ID is unknown or the move would leave the order unchanged.
    func moveTask(id moved: String, before target: String) {
        guard moved != target,
              let fromIdx = tasks.firstIndex(where: { $0.id == moved }) else { return }
        let task = tasks.remove(at: fromIdx)
        guard let targetIdx = tasks.firstIndex(where: { $0.id == target }) else {
            // Target disappeared (shouldn't happen); put it back where it was.
            tasks.insert(task, at: min(fromIdx, tasks.count))
            return
        }
        tasks.insert(task, at: targetIdx)
        saveTasks()
    }

    /// Move `moved` to the very end of the active storage order.
    func moveTaskToEnd(id moved: String) {
        guard let fromIdx = tasks.firstIndex(where: { $0.id == moved }) else { return }
        let task = tasks.remove(at: fromIdx)
        tasks.append(task)
        saveTasks()
    }

    // MARK: - Persistence (SwiftData — single shared ModelContainer)
    
    func dropStaleTasks() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        let stale = tasks.filter { $0.status == .pending && $0.createdAt <= cutoff }
        guard !stale.isEmpty else { return }
        
        tasks.removeAll { task in stale.contains { $0.id == task.id } }
        saveTasks()
        for task in stale {
            NotificationCenter.default.post(name: Self.taskRemoved, object: task)
        }
    }
    //
    // Pattern inherited from `EventCache`: each load/save creates a fresh
    // `ModelContext(modelContainer)` rather than using `container.mainContext`.
    // This avoids the main-actor SwiftData threading hazards that broke
    // v1.10.30–v1.10.41. The store is local-only (no CloudKit), so the
    // initial `loadTasks()` in `init` returns quickly — a few SQLite reads,
    // no network, no authentication.
    //
    // `saveTasks()` performs a full delete-and-reinsert on every mutation.
    // That is O(n) in the number of tasks, but n is small (backlogs of
    // hundreds, not millions), the writes are off-main (fresh context), and
    // the simplicity avoids the whole class of `#Predicate` / `findPersisted`
    // pitfalls that also contributed to the v1.10.30 regression.

    private func loadTasks() {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<PersistedBacklogTask>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        guard let persisted = try? context.fetch(descriptor) else { return }
        tasks = persisted.map { $0.toBacklogTask() }
    }

    private func saveTasks() {
        let context = ModelContext(modelContainer)
        // Wipe existing rows — `tasks` is the source of truth in memory.
        try? context.delete(model: PersistedBacklogTask.self)
        for (index, task) in tasks.enumerated() {
            context.insert(PersistedBacklogTask(from: task, sortOrder: index))
        }
        try? context.save()
    }
}
