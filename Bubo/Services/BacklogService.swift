import Foundation
import SwiftData

// MARK: - Backlog Service

/// Manages persistent task backlog via SwiftData.  When the ModelContainer
/// is configured with CloudKit, tasks sync across devices automatically.
///
/// Performance notes:
/// - Local mutations update the in-memory `tasks` array directly — no
///   full re-fetch after every write.
/// - Full re-fetch happens only on remote CloudKit changes.
/// - `findPersisted` uses a predicate with fetchLimit=1 — O(1) lookup.
/// - Reorder uses fractional indexing (Double sortOrder) so only ONE
///   record is written per move — minimises CloudKit sync conflicts.
@MainActor
@Observable
final class BacklogService {

    /// Posted when a task is marked done. `object` is the task ID (String).
    static let taskCompleted = Notification.Name("BuboBacklogTaskCompleted")
    /// Posted when a task is removed. `object` is the task ID (String).
    static let taskRemoved = Notification.Name("BuboBacklogTaskRemoved")

    private(set) var tasks: [BacklogTask] = []

    /// Last error from a failed SwiftData save.  Observable so UI can
    /// display a non-intrusive warning.  Cleared on next successful save.
    private(set) var lastError: String?

    /// Set when a CloudKit remote change is applied.  UI can show a
    /// subtle "synced just now" indicator.
    private(set) var lastRemoteUpdate: Date?

    private let modelContext: ModelContext
    private var remoteChangeObserver: Any?

    /// Minimum gap between adjacent sortOrder values before a renumber
    /// pass is triggered.  1e-6 gives ~50 halvings before exhaustion.
    private static let minSortGap: Double = 1e-6

    init(modelContainer: ModelContainer) {
        self.modelContext = modelContainer.mainContext
        fetchTasks()
        observeRemoteChanges()
    }

    // MARK: - Remote Change Detection (CloudKit)

    private func observeRemoteChanges() {
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSPersistentStoreRemoteChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchTasks()
                self?.lastRemoteUpdate = Date()
            }
        }
    }

    // MARK: - Queries

    var pending: [BacklogTask] {
        tasks.filter { $0.status == .pending }
    }

    var schedulable: [BacklogTask] {
        tasks.filter { $0.status != .done }
    }

    var scheduled: [BacklogTask] {
        tasks.filter { $0.status == .scheduled }
    }

    var done: [BacklogTask] {
        tasks.filter { $0.status == .done }
    }

    var overdue: [BacklogTask] {
        let today = Calendar.current.startOfDay(for: Date())
        return tasks.filter { task in
            task.status == .scheduled
                && task.scheduledDate != nil
                && task.scheduledDate! < today
        }
    }

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
        let order = nextSortOrder()
        let persisted = PersistedBacklogTask(from: task, sortOrder: order)
        modelContext.insert(persisted)
        guard saveContext() else { return }
        tasks.append(task)
    }

    func addTasks(_ newTasks: [BacklogTask]) {
        let now = Date()
        var order = nextSortOrder()
        for var task in newTasks {
            task.modifiedAt = now
            let persisted = PersistedBacklogTask(from: task, sortOrder: order)
            modelContext.insert(persisted)
            order += 1.0
        }
        guard saveContext() else { return }
        let stamped = newTasks.map { t -> BacklogTask in
            var t = t; t.modifiedAt = now; return t
        }
        tasks.append(contentsOf: stamped)
    }

    func updateTask(_ task: BacklogTask) {
        guard let persisted = findPersisted(taskId: task.id) else { return }
        var task = task
        task.modifiedAt = Date()
        persisted.update(from: task)
        guard saveContext() else { return }
        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[i] = task
        }
    }

    func removeTask(id: String) -> BacklogTask? {
        guard let persisted = findPersisted(taskId: id) else { return nil }
        let removed = persisted.toBacklogTask()
        modelContext.delete(persisted)
        guard saveContext() else { return nil }
        tasks.removeAll { $0.id == id }
        NotificationCenter.default.post(name: Self.taskRemoved, object: id)
        return removed
    }

    func completeTask(id: String) {
        guard let persisted = findPersisted(taskId: id) else { return }
        let now = Date()
        persisted.statusRaw = BacklogStatus.done.rawValue
        persisted.completedAt = now
        persisted.modifiedAt = now
        guard saveContext() else { return }
        if let i = tasks.firstIndex(where: { $0.id == id }) {
            tasks[i].status = .done
            tasks[i].completedAt = now
            tasks[i].modifiedAt = now
        }
        NotificationCenter.default.post(name: Self.taskCompleted, object: id)
    }

    func silentlyComplete(id: String) {
        guard let persisted = findPersisted(taskId: id) else { return }
        let now = Date()
        persisted.statusRaw = BacklogStatus.done.rawValue
        persisted.completedAt = now
        persisted.modifiedAt = now
        guard saveContext() else { return }
        if let i = tasks.firstIndex(where: { $0.id == id }) {
            tasks[i].status = .done
            tasks[i].completedAt = now
            tasks[i].modifiedAt = now
        }
    }

    func markScheduled(id: String, eventId: String, date: Date) {
        guard let persisted = findPersisted(taskId: id) else { return }
        let now = Date()
        persisted.statusRaw = BacklogStatus.scheduled.rawValue
        persisted.scheduledEventId = eventId
        persisted.scheduledDate = date
        persisted.modifiedAt = now
        guard saveContext() else { return }
        if let i = tasks.firstIndex(where: { $0.id == id }) {
            tasks[i].status = .scheduled
            tasks[i].scheduledEventId = eventId
            tasks[i].scheduledDate = date
            tasks[i].modifiedAt = now
        }
    }

    func unschedule(id: String) {
        guard let persisted = findPersisted(taskId: id) else { return }
        let now = Date()
        persisted.statusRaw = BacklogStatus.pending.rawValue
        persisted.scheduledEventId = nil
        persisted.scheduledDate = nil
        persisted.modifiedAt = now
        guard saveContext() else { return }
        if let i = tasks.firstIndex(where: { $0.id == id }) {
            tasks[i].status = .pending
            tasks[i].scheduledEventId = nil
            tasks[i].scheduledDate = nil
            tasks[i].modifiedAt = now
        }
    }

    func restoreTask(_ task: BacklogTask, at index: Int? = nil) {
        var task = task
        task.modifiedAt = Date()

        let order: Double
        if let index, index >= 0, index < tasks.count {
            order = sortOrderBefore(index: index)
        } else {
            order = nextSortOrder()
        }
        let persisted = PersistedBacklogTask(from: task, sortOrder: order)
        modelContext.insert(persisted)
        guard saveContext() else { return }

        if let index, index >= 0, index <= tasks.count {
            tasks.insert(task, at: index)
        } else {
            tasks.append(task)
        }
    }

    func indexOfTask(id: String) -> Int? {
        tasks.firstIndex(where: { $0.id == id })
    }

    func carryOverUnfinished() {
        let today = Calendar.current.startOfDay(for: Date())
        let now = Date()

        let scheduled = BacklogStatus.scheduled.rawValue
        var descriptor = FetchDescriptor<PersistedBacklogTask>(
            predicate: #Predicate<PersistedBacklogTask> { task in
                task.statusRaw == scheduled
            }
        )
        descriptor.fetchLimit = 500
        guard let results = try? modelContext.fetch(descriptor) else { return }

        var changed = false
        for persisted in results {
            guard let date = persisted.scheduledDate, date < today else { continue }
            persisted.statusRaw = BacklogStatus.pending.rawValue
            persisted.scheduledEventId = nil
            persisted.scheduledDate = nil
            persisted.modifiedAt = now
            changed = true
        }
        if changed {
            guard saveContext() else { return }
            fetchTasks()
        }
    }

    // MARK: - Reorder (fractional indexing — only 1 record touched)

    func reorderTask(from: Int, to: Int) {
        let active = tasks.filter { $0.status != .done }
        guard from < active.count, to < active.count else { return }
        let movedId = active[from].id
        let targetId = active[to].id
        guard let fromGlobal = tasks.firstIndex(where: { $0.id == movedId }),
              let toGlobal = tasks.firstIndex(where: { $0.id == targetId }) else { return }
        let task = tasks.remove(at: fromGlobal)
        tasks.insert(task, at: toGlobal)
        persistMovedTask(id: movedId)
    }

    func moveTask(id moved: String, before target: String) {
        guard moved != target,
              let fromIdx = tasks.firstIndex(where: { $0.id == moved }) else { return }
        let task = tasks.remove(at: fromIdx)
        guard let targetIdx = tasks.firstIndex(where: { $0.id == target }) else {
            tasks.insert(task, at: min(fromIdx, tasks.count))
            return
        }
        tasks.insert(task, at: targetIdx)
        persistMovedTask(id: moved)
    }

    func moveTaskToEnd(id moved: String) {
        guard let fromIdx = tasks.firstIndex(where: { $0.id == moved }) else { return }
        let task = tasks.remove(at: fromIdx)
        tasks.append(task)
        persistMovedTask(id: moved)
    }

    // MARK: - SwiftData Persistence

    /// O(1) lookup via predicate + fetchLimit.
    private func findPersisted(taskId: String) -> PersistedBacklogTask? {
        let id = taskId
        var descriptor = FetchDescriptor<PersistedBacklogTask>(
            predicate: #Predicate<PersistedBacklogTask> { $0.taskId == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Full fetch — called once at init and on remote CloudKit changes.
    private func fetchTasks() {
        let descriptor = FetchDescriptor<PersistedBacklogTask>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        guard let persisted = try? modelContext.fetch(descriptor) else { return }
        tasks = persisted.map { $0.toBacklogTask() }
    }

    /// Save with error tracking.  Returns `true` on success.
    @discardableResult
    private func saveContext() -> Bool {
        do {
            try modelContext.save()
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Fractional Sort Order

    /// sortOrder for a new task appended at the end.
    private func nextSortOrder() -> Double {
        let descriptor = FetchDescriptor<PersistedBacklogTask>(
            sortBy: [SortDescriptor(\.sortOrder, order: .reverse)]
        )
        var d = descriptor
        d.fetchLimit = 1
        let last = try? modelContext.fetch(d).first
        return (last?.sortOrder ?? 0) + 1.0
    }

    /// sortOrder that places a task just before `index` in the current
    /// `tasks` array.  Uses fractional midpoint.
    private func sortOrderBefore(index: Int) -> Double {
        guard index < tasks.count else { return nextSortOrder() }

        let afterId = tasks[index].id
        let afterOrder = findPersisted(taskId: afterId)?.sortOrder ?? Double(index)

        if index == 0 {
            return afterOrder - 1.0
        }

        let beforeId = tasks[index - 1].id
        let beforeOrder = findPersisted(taskId: beforeId)?.sortOrder ?? (afterOrder - 1.0)

        let mid = (beforeOrder + afterOrder) / 2.0
        if afterOrder - beforeOrder < Self.minSortGap {
            renumberAll()
            return sortOrderBefore(index: index)   // retry with fresh gaps
        }
        return mid
    }

    /// After an in-memory reorder, persist only the moved task's sortOrder.
    /// Computes a fractional midpoint between its new neighbours.
    private func persistMovedTask(id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }),
              let persisted = findPersisted(taskId: id) else { return }

        let newOrder: Double
        if tasks.count == 1 {
            newOrder = 0
        } else if idx == 0 {
            let nextOrder = findPersisted(taskId: tasks[1].id)?.sortOrder ?? 1.0
            newOrder = nextOrder - 1.0
        } else if idx == tasks.count - 1 {
            let prevOrder = findPersisted(taskId: tasks[idx - 1].id)?.sortOrder ?? Double(idx - 1)
            newOrder = prevOrder + 1.0
        } else {
            let prevOrder = findPersisted(taskId: tasks[idx - 1].id)?.sortOrder ?? Double(idx - 1)
            let nextOrder = findPersisted(taskId: tasks[idx + 1].id)?.sortOrder ?? Double(idx + 1)
            if nextOrder - prevOrder < Self.minSortGap {
                renumberAll()
                return
            }
            newOrder = (prevOrder + nextOrder) / 2.0
        }

        persisted.sortOrder = newOrder
        saveContext()
    }

    /// Emergency renumber — assigns sequential values with 1.0 gaps.
    /// O(n) but only triggered when fractional gaps are exhausted (~50+
    /// consecutive reorders between the same two tasks).
    private func renumberAll() {
        let descriptor = FetchDescriptor<PersistedBacklogTask>()
        guard let all = try? modelContext.fetch(descriptor) else { return }
        let byId = Dictionary(
            all.map { ($0.taskId, $0) },
            uniquingKeysWith: { _, b in b }
        )
        for (i, task) in tasks.enumerated() {
            byId[task.id]?.sortOrder = Double(i)
        }
        saveContext()
    }
}
