import Foundation
import SwiftData

// MARK: - Backlog Service

/// Manages persistent task backlog via SwiftData.  When the ModelContainer
/// is configured with CloudKit, tasks sync across devices automatically —
/// no manual merge logic required.
@MainActor
@Observable
final class BacklogService {

    /// Posted when a task is marked done. `object` is the task ID (String).
    static let taskCompleted = Notification.Name("BuboBacklogTaskCompleted")
    /// Posted when a task is removed. `object` is the task ID (String).
    static let taskRemoved = Notification.Name("BuboBacklogTaskRemoved")

    private(set) var tasks: [BacklogTask] = []
    private let modelContext: ModelContext
    private var remoteChangeObserver: Any?

    init(modelContainer: ModelContainer) {
        self.modelContext = modelContainer.mainContext
        fetchTasks()
        observeRemoteChanges()
    }

    // MARK: - Remote Change Detection (CloudKit)

    /// Re-fetch when CloudKit delivers remote changes to the local store.
    private func observeRemoteChanges() {
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSPersistentStoreRemoteChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchTasks()
            }
        }
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
        var task = task
        task.modifiedAt = Date()
        let persisted = PersistedBacklogTask(from: task, sortOrder: tasks.count)
        modelContext.insert(persisted)
        save()
    }

    func addTasks(_ newTasks: [BacklogTask]) {
        let now = Date()
        var offset = tasks.count
        for var task in newTasks {
            task.modifiedAt = now
            let persisted = PersistedBacklogTask(from: task, sortOrder: offset)
            modelContext.insert(persisted)
            offset += 1
        }
        save()
    }

    func updateTask(_ task: BacklogTask) {
        guard let persisted = findPersisted(taskId: task.id) else { return }
        var task = task
        task.modifiedAt = Date()
        persisted.update(from: task)
        save()
    }

    func removeTask(id: String) -> BacklogTask? {
        guard let persisted = findPersisted(taskId: id) else { return nil }
        let removed = persisted.toBacklogTask()
        modelContext.delete(persisted)
        save()
        NotificationCenter.default.post(name: Self.taskRemoved, object: id)
        return removed
    }

    func completeTask(id: String) {
        guard let persisted = findPersisted(taskId: id) else { return }
        let now = Date()
        persisted.statusRaw = BacklogStatus.done.rawValue
        persisted.completedAt = now
        persisted.modifiedAt = now
        save()
        NotificationCenter.default.post(name: Self.taskCompleted, object: id)
    }

    /// Marks a task done without posting `taskCompleted`. Used by
    /// RemindersSyncService when the completion originated externally
    /// (from Reminders.app) so we don't write it back in a loop.
    func silentlyComplete(id: String) {
        guard let persisted = findPersisted(taskId: id) else { return }
        let now = Date()
        persisted.statusRaw = BacklogStatus.done.rawValue
        persisted.completedAt = now
        persisted.modifiedAt = now
        save()
    }

    func markScheduled(id: String, eventId: String, date: Date) {
        guard let persisted = findPersisted(taskId: id) else { return }
        persisted.statusRaw = BacklogStatus.scheduled.rawValue
        persisted.scheduledEventId = eventId
        persisted.scheduledDate = date
        persisted.modifiedAt = Date()
        save()
    }

    func unschedule(id: String) {
        guard let persisted = findPersisted(taskId: id) else { return }
        persisted.statusRaw = BacklogStatus.pending.rawValue
        persisted.scheduledEventId = nil
        persisted.scheduledDate = nil
        persisted.modifiedAt = Date()
        save()
    }

    /// Re-insert a previously removed task (for undo).
    /// When `index` is provided we try to put the task back where it was so
    /// the user-controlled order survives the delete/undo round-trip; falls
    /// back to appending if the index is out of range or nil.
    func restoreTask(_ task: BacklogTask, at index: Int? = nil) {
        var task = task
        task.modifiedAt = Date()

        let order: Int
        if let index, index >= 0, index <= tasks.count {
            order = index
        } else {
            order = tasks.count
        }
        let persisted = PersistedBacklogTask(from: task, sortOrder: order)
        modelContext.insert(persisted)
        save()
        // Fix sort order so the restored task sits at the right position.
        persistOrder()
    }

    /// Current global index of a task by ID, or nil if it's not in the list.
    /// Callers capture this before `removeTask` so undo can restore position.
    func indexOfTask(id: String) -> Int? {
        tasks.firstIndex(where: { $0.id == id })
    }

    /// Move tasks that were scheduled in the past but not completed back to pending.
    func carryOverUnfinished() {
        let today = Calendar.current.startOfDay(for: Date())
        let now = Date()
        let descriptor = FetchDescriptor<PersistedBacklogTask>()
        guard let all = try? modelContext.fetch(descriptor) else { return }

        var changed = false
        for persisted in all {
            if persisted.statusRaw == BacklogStatus.scheduled.rawValue,
               let scheduled = persisted.scheduledDate,
               scheduled < today {
                persisted.statusRaw = BacklogStatus.pending.rawValue
                persisted.scheduledEventId = nil
                persisted.scheduledDate = nil
                persisted.modifiedAt = now
                changed = true
            }
        }
        if changed { save() }
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
        persistOrder()
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
        persistOrder()
    }

    /// Move `moved` to the very end of the active storage order.
    func moveTaskToEnd(id moved: String) {
        guard let fromIdx = tasks.firstIndex(where: { $0.id == moved }) else { return }
        let task = tasks.remove(at: fromIdx)
        tasks.append(task)
        persistOrder()
    }

    // MARK: - SwiftData Persistence

    private func findPersisted(taskId: String) -> PersistedBacklogTask? {
        let descriptor = FetchDescriptor<PersistedBacklogTask>()
        guard let all = try? modelContext.fetch(descriptor) else { return nil }
        return all.first { $0.taskId == taskId }
    }

    private func fetchTasks() {
        let descriptor = FetchDescriptor<PersistedBacklogTask>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        guard let persisted = try? modelContext.fetch(descriptor) else { return }
        tasks = persisted.map { $0.toBacklogTask() }
    }

    /// Write in-memory `tasks` ordering back to SwiftData sort-order field.
    private func persistOrder() {
        let descriptor = FetchDescriptor<PersistedBacklogTask>()
        guard let all = try? modelContext.fetch(descriptor) else { return }
        let byId = Dictionary(
            all.map { ($0.taskId, $0) },
            uniquingKeysWith: { _, b in b }
        )
        for (index, task) in tasks.enumerated() {
            byId[task.id]?.sortOrder = index
        }
        save()
    }

    private func save() {
        try? modelContext.save()
        fetchTasks()
    }
}
