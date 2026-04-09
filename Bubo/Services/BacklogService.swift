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
    var groupedByContext: [(context: String?, tasks: [BacklogTask])] {
        let active = tasks.filter { $0.status != .done }
        let grouped = Dictionary(grouping: active) { $0.context }
        return grouped
            .sorted { ($0.key ?? "zzz") < ($1.key ?? "zzz") }
            .map { (context: $0.key, tasks: $0.value.sorted { lhs, rhs in
                // Urgent first (deadline), then priority, then creation date
                if let ld = lhs.deadline, let rd = rhs.deadline {
                    return ld < rd
                }
                if lhs.deadline != nil { return true }
                if rhs.deadline != nil { return false }
                if lhs.priority != rhs.priority {
                    return lhs.priority.numericValue > rhs.priority.numericValue
                }
                return lhs.createdAt < rhs.createdAt
            }) }
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
    func restoreTask(_ task: BacklogTask) {
        tasks.append(task)
        saveTasks()
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
