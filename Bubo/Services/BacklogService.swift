import Foundation
import SwiftData

// MARK: - Backlog Service

/// Manages persistent task backlog. Tasks live here until completed —
/// never consumed by optimization, automatically carried over across days.
@MainActor
@Observable
final class BacklogService {

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
        tasks.append(task)
        saveTasks()
    }

    func addTasks(_ newTasks: [BacklogTask]) {
        tasks.append(contentsOf: newTasks)
        saveTasks()
    }

    func updateTask(_ task: BacklogTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
        saveTasks()
    }

    func removeTask(id: String) -> BacklogTask? {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = tasks.remove(at: index)
        saveTasks()
        return removed
    }

    func completeTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .done
        tasks[index].completedAt = Date()
        saveTasks()
    }

    func markScheduled(id: String, eventId: String, date: Date) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .scheduled
        tasks[index].scheduledEventId = eventId
        tasks[index].scheduledDate = date
        saveTasks()
    }

    func unschedule(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .pending
        tasks[index].scheduledEventId = nil
        tasks[index].scheduledDate = nil
        saveTasks()
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

    // MARK: - Persistence (UserDefaults for simplicity; could migrate to SwiftData)

    private let persistenceKey = "BuboBacklogTasks"

    private func loadTasks() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([BacklogTask].self, from: data) else {
            return
        }
        tasks = decoded
    }

    private func saveTasks() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }
}
