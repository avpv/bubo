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
    /// Frozen and done tasks are both excluded: `.frozen` is the user's
    /// explicit "set aside, don't plan around this" signal.
    var schedulable: [BacklogTask] {
        tasks.filter { $0.status != .done && $0.status != .frozen }
    }

    /// Tasks that have been placed in the schedule.
    var scheduled: [BacklogTask] {
        tasks.filter { $0.status == .scheduled }
    }

    /// Completed tasks.
    var done: [BacklogTask] {
        tasks.filter { $0.status == .done }
    }

    /// Frozen — user-archived tasks. Not consumed by optimization, not
    /// displayed in the active list; surfaced only through the frozen tombstone.
    var frozen: [BacklogTask] {
        tasks.filter { $0.status == .frozen }
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
        let active = tasks.filter { $0.status != .done && $0.status != .frozen }
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
        BacklogLogic.urgentTasks(tasks, withinDays: days)
    }

    // MARK: - Mutations

    func addTask(_ task: BacklogTask) {
        let index = tasks.count
        tasks.append(task)
        persistInsert(task, at: index)
        NotificationCenter.default.post(name: Self.taskAdded, object: task.id)
    }

    func addTasks(_ newTasks: [BacklogTask]) {
        let baseIndex = tasks.count
        tasks.append(contentsOf: newTasks)
        for (offset, task) in newTasks.enumerated() {
            persistInsert(task, at: baseIndex + offset)
        }
        for task in newTasks {
            NotificationCenter.default.post(name: Self.taskAdded, object: task.id)
        }
    }

    func updateTask(_ task: BacklogTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let existing = tasks[index]
        // Skip no-op updates — without this, every autosave keystroke would
        // bump `modifiedAt` and kick observers. Identity on the struct covers
        // every field we persist (see `BacklogTask: Hashable`) except for
        // `modifiedAt` itself, which we're about to set.
        var incoming = task
        incoming.modifiedAt = existing.modifiedAt
        guard incoming != existing else { return }
        // Stamp a fresh `modifiedAt` so CloudKit-driven merges on other
        // devices can tell which copy of the task is newer. Callers that
        // *don't* want to bump the stamp (notably `silentlyUpdate`, which
        // applies remote edits back into the local store) have their own
        // code path that skips this.
        incoming.modifiedAt = Date()
        tasks[index] = incoming
        persistUpdate(incoming, at: index)
        NotificationCenter.default.post(name: Self.taskUpdated, object: incoming.id)
    }

    /// Update without posting `taskUpdated`. Used by `RemindersSyncService`
    /// when merging fields it just read from Apple Reminders — posting
    /// `taskUpdated` there would cause the writeback observer to push the
    /// same data straight back to the reminder we read from.
    func silentlyUpdate(_ task: BacklogTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
        persistUpdate(task, at: index)
    }

    func removeTask(id: String) -> BacklogTask? {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = tasks.remove(at: index)
        persistRemove(id: id)
        persistReorder(fromIndex: index)
        // Post the full task so observers can inspect fields like
        // `reminderCalendarItemId` for cleanup of external state — the task
        // is already gone from `tasks` by the time they receive this.
        NotificationCenter.default.post(name: Self.taskRemoved, object: removed)
        return removed
    }

    func completeTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        let now = Date()
        if tasks[index].isRecurring {
            // Recurring tasks reset instead of moving to `.done`: the row
            // survives the completion gesture, ready for the next occurrence.
            // `createdAt` is refreshed so "stale" logic treats this as new,
            // and any prior schedule linkage is dropped so the task re-enters
            // planning cleanly next time. `deadline` is advanced by the
            // `RecurrenceEngine` so a "weekly review" completed on Friday
            // re-surfaces next Friday instead of staying at today's urgency.
            tasks[index].status = .pending
            tasks[index].completedAt = now
            tasks[index].createdAt = now
            tasks[index].scheduledEventId = nil
            tasks[index].scheduledDate = nil
            if let next = RecurrenceEngine.nextOccurrence(
                after: now,
                tag: tasks[index].recurrenceTag
            ) {
                tasks[index].deadline = next
            }
        } else {
            tasks[index].status = .done
            tasks[index].completedAt = now
        }

        persistUpdate(tasks[index], at: index)
        NotificationCenter.default.post(name: Self.taskCompleted, object: id)
    }

    /// Set aside a task without deleting it. The task leaves the active list
    /// and stops participating in optimization, but stays in storage under
    /// `frozen`. Complements delete (destructive) — Birman: «данные драгоценны».
    func freezeTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .frozen
        // Drop schedule linkage so the calendar slot is freed.
        tasks[index].scheduledEventId = nil
        tasks[index].scheduledDate = nil
        persistUpdate(tasks[index], at: index)
        NotificationCenter.default.post(name: Self.taskUpdated, object: id)
        NotificationCenter.default.post(name: Self.taskScheduleChanged, object: id)
    }

    /// Restore a frozen task to the backlog so it can be scheduled again.
    func unfreezeTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].status == .frozen else { return }
        tasks[index].status = .pending
        persistUpdate(tasks[index], at: index)
        NotificationCenter.default.post(name: Self.taskUpdated, object: id)
    }

    /// Bulk restore — powers the "Unfreeze all" button on the frozen tombstone.
    func unfreezeAll() {
        var changedIndexes: [Int] = []
        for i in tasks.indices where tasks[i].status == .frozen {
            tasks[i].status = .pending
            changedIndexes.append(i)
        }
        if !changedIndexes.isEmpty {
            for i in changedIndexes {
                persistUpdate(tasks[i], at: i)
            }
            NotificationCenter.default.post(name: Self.taskUpdated, object: nil)
        }
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
        persistUpdate(tasks[index], at: index)
    }

    /// Store the Apple Reminders `calendarItemIdentifier` for a Bubo-native
    /// task without firing any notifications. Used by `RemindersSyncService`
    /// right after creating the linked reminder — we need to remember the ID
    /// so future syncs dedupe correctly, but any notification here would
    /// kick off another export attempt.
    func silentlyUpdateReminderMapping(taskId: String, calendarItemId: String?) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[index].reminderCalendarItemId = calendarItemId
        persistUpdate(tasks[index], at: index)
    }

    func markScheduled(id: String, eventId: String, date: Date) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .scheduled
        tasks[index].scheduledEventId = eventId
        tasks[index].scheduledDate = date
        persistUpdate(tasks[index], at: index)
        NotificationCenter.default.post(name: Self.taskScheduleChanged, object: id)
    }

    func unschedule(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .pending
        tasks[index].scheduledEventId = nil
        tasks[index].scheduledDate = nil
        persistUpdate(tasks[index], at: index)
        NotificationCenter.default.post(name: Self.taskScheduleChanged, object: id)
    }

    /// Re-insert a previously removed task (for undo).
    /// When `index` is provided we try to put the task back where it was so
    /// the user-controlled order survives the delete/undo round-trip; falls
    /// back to appending if the index is out of range or nil.
    func restoreTask(_ task: BacklogTask, at index: Int? = nil) {
        let insertIndex: Int
        if let index, index >= 0, index <= tasks.count {
            tasks.insert(task, at: index)
            insertIndex = index
        } else {
            tasks.append(task)
            insertIndex = tasks.count - 1
        }
        persistInsert(task, at: insertIndex)
        persistReorder(fromIndex: insertIndex + 1)
    }

    /// Current global index of a task by ID, or nil if it's not in the list.
    /// Callers capture this before `removeTask` so undo can restore position.
    func indexOfTask(id: String) -> Int? {
        tasks.firstIndex(where: { $0.id == id })
    }

    /// Move tasks that were scheduled in the past but not completed back to pending.
    func carryOverUnfinished() {
        let today = Calendar.current.startOfDay(for: Date())
        var changedIndexes: [Int] = []
        for i in tasks.indices {
            if tasks[i].status == .scheduled,
               let scheduled = tasks[i].scheduledDate,
               scheduled < today {
                tasks[i].status = .pending
                tasks[i].scheduledEventId = nil
                tasks[i].scheduledDate = nil
                changedIndexes.append(i)
            }
        }
        for i in changedIndexes {
            persistUpdate(tasks[i], at: i)
        }
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
        persistReorder(fromIndex: min(fromGlobal, toGlobal))
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
        persistReorder(fromIndex: min(fromIdx, targetIdx))
    }

    /// Move `moved` to the very end of the active storage order.
    func moveTaskToEnd(id moved: String) {
        guard let fromIdx = tasks.firstIndex(where: { $0.id == moved }) else { return }
        let task = tasks.remove(at: fromIdx)
        tasks.append(task)
        persistReorder(fromIndex: fromIdx)
    }

    // MARK: - Persistence (SwiftData — single shared ModelContainer)

    func dropStaleTasks() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        let stale = tasks.filter { $0.status == .pending && $0.createdAt <= cutoff }
        guard !stale.isEmpty else { return }

        let staleIds = Set(stale.map(\.id))
        let firstRemovedIndex = tasks.firstIndex(where: { staleIds.contains($0.id) }) ?? tasks.count
        tasks.removeAll { staleIds.contains($0.id) }
        for id in staleIds {
            persistRemove(id: id)
        }
        persistReorder(fromIndex: firstRemovedIndex)
        for task in stale {
            NotificationCenter.default.post(name: Self.taskRemoved, object: task)
        }
    }

    // Pattern inherited from `EventCache`: each load/save creates a fresh
    // `ModelContext(modelContainer)` rather than using `container.mainContext`.
    // This avoids the main-actor SwiftData threading hazards that broke
    // v1.10.30–v1.10.41.
    //
    // Persistence is now **targeted per mutation** — `persistInsert`,
    // `persistUpdate`, `persistRemove` and `persistReorder` each touch only
    // the rows that actually changed, using `#Predicate` to scope the fetch
    // to one row (or a sortOrder range for reorder). The legacy `saveAll()`
    // reconciliation remains as a safety net for tests that need to force
    // a full rewrite of the store, but no production path calls it.

    private func loadTasks() {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<PersistedBacklogTask>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        guard let persisted = try? context.fetch(descriptor) else { return }
        tasks = persisted.map { $0.toBacklogTask() }
    }

    /// Fetch exactly one persisted row by taskId, via predicate, so we
    /// don't pull the whole table to find one record.
    private func fetchPersisted(taskId: String, context: ModelContext) -> PersistedBacklogTask? {
        var descriptor = FetchDescriptor<PersistedBacklogTask>(
            predicate: #Predicate { $0.taskId == taskId }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func persistInsert(_ task: BacklogTask, at sortOrder: Int) {
        let context = ModelContext(modelContainer)
        // Defensive: if the same id already exists (e.g. a CloudKit merge
        // landed a row before our local insert), update in place rather
        // than creating a duplicate that a later dedup pass would have to
        // clean up.
        if let existing = fetchPersisted(taskId: task.id, context: context) {
            existing.apply(task, sortOrder: sortOrder)
        } else {
            context.insert(PersistedBacklogTask(from: task, sortOrder: sortOrder))
        }
        try? context.save()
    }

    private func persistUpdate(_ task: BacklogTask, at sortOrder: Int) {
        let context = ModelContext(modelContainer)
        if let row = fetchPersisted(taskId: task.id, context: context) {
            row.apply(task, sortOrder: sortOrder)
        } else {
            // Row vanished on us (e.g. remote delete); recreate to keep
            // memory and disk in sync.
            context.insert(PersistedBacklogTask(from: task, sortOrder: sortOrder))
        }
        try? context.save()
    }

    private func persistRemove(id: String) {
        let context = ModelContext(modelContainer)
        if let row = fetchPersisted(taskId: id, context: context) {
            context.delete(row)
            try? context.save()
        }
    }

    /// Rewrite `sortOrder` for rows at or after `fromIndex` to match the
    /// in-memory array. Touched-rows-only: we don't reassign the whole
    /// table — anything before `fromIndex` already has the correct index.
    private func persistReorder(fromIndex: Int) {
        guard fromIndex >= 0, fromIndex < tasks.count else { return }
        let context = ModelContext(modelContainer)
        let affected = tasks[fromIndex...]
        for (offset, task) in affected.enumerated() {
            let expectedOrder = fromIndex + offset
            guard let row = fetchPersisted(taskId: task.id, context: context) else { continue }
            if row.sortOrder != expectedOrder {
                row.sortOrder = expectedOrder
            }
        }
        try? context.save()
    }

    /// Full reconcile: fetch every row and align the store to `tasks`.
    /// Preserved as a safety net for tests + future bulk import paths;
    /// production mutations use the targeted `persist*` helpers above.
    func saveAll() {
        let context = ModelContext(modelContainer)
        let existing = (try? context.fetch(FetchDescriptor<PersistedBacklogTask>())) ?? []
        // Group by taskId so a duplicate row (possible during a CloudKit
        // merge window) doesn't trap `Dictionary(uniqueKeysWithValues:)`.
        // Duplicates are collapsed: the first instance is kept and the
        // others are deleted so the store converges to one row per task.
        var byId: [String: PersistedBacklogTask] = [:]
        for row in existing {
            if byId[row.taskId] == nil {
                byId[row.taskId] = row
            } else {
                context.delete(row)
            }
        }

        let liveIds = Set(tasks.map(\.id))
        for (id, row) in byId where !liveIds.contains(id) {
            context.delete(row)
            byId.removeValue(forKey: id)
        }

        for (index, task) in tasks.enumerated() {
            if let row = byId[task.id] {
                row.apply(task, sortOrder: index)
            } else {
                context.insert(PersistedBacklogTask(from: task, sortOrder: index))
            }
        }

        try? context.save()
    }
}
