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

    /// Backlog persistence, isolated behind a protocol so tests can swap
    /// in `InMemoryBacklogTaskStore` without a SwiftData container. The
    /// production path wires in `BacklogTaskStore`.
    private let store: any BacklogTaskStoring
    /// See `RemindersSyncService` — `Any?` NotificationCenter tokens need to
    /// be readable from `deinit`, which is nonisolated on a `@MainActor` class.
    private nonisolated(unsafe) var cloudImportObserver: Any?

    /// Production initializer. Builds the SwiftData-backed store from
    /// the container.
    convenience init(modelContainer: ModelContainer) {
        self.init(store: BacklogTaskStore(container: modelContainer))
    }

    /// Designated initializer. Takes the store by protocol so tests can
    /// inject `InMemoryBacklogTaskStore`.
    init(store: any BacklogTaskStoring) {
        self.store = store
        tasks = store.loadAll()

        // After every successful CloudKit import, re-load from disk and
        // reconcile monotonic fields that last-writer-wins could otherwise
        // regress (see `BacklogTask.merged`). This is the bridge between
        // SwiftData's silent merge and our domain invariants.
        cloudImportObserver = NotificationCenter.default.addObserver(
            forName: CloudKitSyncMonitor.didFinishImport,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileAfterCloudImport()
            }
        }
    }

    deinit {
        if let o = cloudImportObserver { NotificationCenter.default.removeObserver(o) }
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
        store.upsert(task, at: index)
        NotificationCenter.default.post(name: Self.taskAdded, object: task.id)
    }

    func addTasks(_ newTasks: [BacklogTask]) {
        let baseIndex = tasks.count
        tasks.append(contentsOf: newTasks)
        for (offset, task) in newTasks.enumerated() {
            store.upsert(task, at: baseIndex + offset)
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
        store.upsert(incoming, at: index)
        NotificationCenter.default.post(name: Self.taskUpdated, object: incoming.id)
    }

    /// Update without posting `taskUpdated`. Used by `RemindersSyncService`
    /// when merging fields it just read from Apple Reminders — posting
    /// `taskUpdated` there would cause the writeback observer to push the
    /// same data straight back to the reminder we read from.
    func silentlyUpdate(_ task: BacklogTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
        store.upsert(task, at: index)
    }

    func removeTask(id: String) -> BacklogTask? {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = tasks.remove(at: index)
        store.delete(id: id)
        store.reorder(fromIndex: index, tasks: tasks)
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
            tasks[index].scheduledEventIds = []
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

        store.upsert(tasks[index], at: index)
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
        tasks[index].scheduledEventIds = []
        tasks[index].scheduledDate = nil
        store.upsert(tasks[index], at: index)
        NotificationCenter.default.post(name: Self.taskUpdated, object: id)
        NotificationCenter.default.post(name: Self.taskScheduleChanged, object: id)
    }

    /// Restore a frozen task to the backlog so it can be scheduled again.
    func unfreezeTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].status == .frozen else { return }
        tasks[index].status = .pending
        store.upsert(tasks[index], at: index)
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
                store.upsert(tasks[i], at: i)
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
        store.upsert(tasks[index], at: index)
    }

    /// Store the Apple Reminders `calendarItemIdentifier` for a Bubo-native
    /// task without firing any notifications. Used by `RemindersSyncService`
    /// right after creating the linked reminder — we need to remember the ID
    /// so future syncs dedupe correctly, but any notification here would
    /// kick off another export attempt.
    func silentlyUpdateReminderMapping(taskId: String, calendarItemId: String?) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[index].reminderCalendarItemId = calendarItemId
        store.upsert(tasks[index], at: index)
    }

    /// Single-event convenience: most paths in the app schedule a backlog
    /// task into exactly one calendar slot.
    func markScheduled(id: String, eventId: String, date: Date) {
        markScheduled(id: id, eventIds: [eventId], date: date)
    }

    /// List form for auto-chunked long tasks, where the GA produces multiple
    /// `CalendarEvent`s (one per chunk). The primary `scheduledEventId` is
    /// set to the first entry so legacy readers keep working; the full list
    /// flows through `scheduledEventIds` so unschedule/reschedule can find
    /// every slice. `eventIds` must be non-empty.
    func markScheduled(id: String, eventIds: [String], date: Date) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              let primary = eventIds.first else { return }
        tasks[index].status = .scheduled
        tasks[index].scheduledEventId = primary
        tasks[index].scheduledEventIds = eventIds
        tasks[index].scheduledDate = date
        store.upsert(tasks[index], at: index)
        NotificationCenter.default.post(name: Self.taskScheduleChanged, object: id)
    }

    func unschedule(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .pending
        tasks[index].scheduledEventId = nil
        tasks[index].scheduledEventIds = []
        tasks[index].scheduledDate = nil
        store.upsert(tasks[index], at: index)
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
        store.upsert(task, at: insertIndex)
        store.reorder(fromIndex: insertIndex + 1, tasks: tasks)
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
                tasks[i].scheduledEventIds = []
                tasks[i].scheduledDate = nil
                changedIndexes.append(i)
            }
        }
        for i in changedIndexes {
            store.upsert(tasks[i], at: i)
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
        store.reorder(fromIndex: min(fromGlobal, toGlobal), tasks: tasks)
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
        store.reorder(fromIndex: min(fromIdx, targetIdx), tasks: tasks)
    }

    // MARK: Pin / unpin
    //
    // Pinning is the user's manual override of `BacklogLogic.smartScore`.
    // When the smart-sorted list is shown (Sprint, or Backlog with Smart Sort
    // on), pinned tasks float to the top in `pinnedRank` order; everything
    // else keeps its algorithm-derived position. Storage order is untouched —
    // this is a parallel signal, so toggling Smart Sort off restores the
    // user's drag order untouched.
    //
    // Birman: данные пользователя сильнее автоматики, но автоматика остаётся
    // включённой для всех остальных строк.

    /// Pin `id` so it lands on top of the smart-sorted list. If `before` is
    /// non-nil, the new pin slots immediately above that pinned task; otherwise
    /// it goes to the very top (rank 0) and existing pins shift down.
    /// No-op if `id` is unknown.
    func pinTask(id: String, before: String? = nil) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        // Build the current pinned sequence in rank order.
        var pinned = tasks
            .enumerated()
            .compactMap { (storageIdx, t) -> (storageIdx: Int, taskId: String, rank: Int)? in
                guard let rank = t.pinnedRank else { return nil }
                return (storageIdx, t.id, rank)
            }
            .sorted { $0.rank < $1.rank }
        // Remove the moving id from its old slot, if it was already pinned.
        pinned.removeAll { $0.taskId == id }
        // Three drop semantics for the smart-sorted list:
        //   - `before == nil`            → pin to the very top (rank 0)
        //   - `before` is itself pinned  → insert at that pin's rank
        //   - `before` is *unpinned*     → append to the pin list, so the new
        //     pin lands above all unpinned tasks (and therefore above the
        //     drop target, which is unpinned by definition). Avoids the
        //     "every drop fights for rank 0" loop.
        let insertAt: Int
        if let before {
            if let idx = pinned.firstIndex(where: { $0.taskId == before }) {
                insertAt = idx
            } else {
                insertAt = pinned.count
            }
        } else {
            insertAt = 0
        }
        pinned.insert((0, id, 0), at: insertAt)
        // Reassign ranks 0…N-1 over the new sequence and write back any rows
        // whose rank actually changed.
        var changed: [Int] = []
        for (newRank, entry) in pinned.enumerated() {
            guard let storageIdx = tasks.firstIndex(where: { $0.id == entry.taskId }) else { continue }
            if tasks[storageIdx].pinnedRank != newRank {
                tasks[storageIdx].pinnedRank = newRank
                tasks[storageIdx].modifiedAt = Date()
                changed.append(storageIdx)
            }
        }
        for i in changed {
            store.upsert(tasks[i], at: i)
        }
        if !changed.isEmpty {
            NotificationCenter.default.post(name: Self.taskUpdated, object: id)
        }
    }

    /// Drop `id`'s pin. The remaining pins are re-numbered to a contiguous
    /// 0…N-1 sequence so a later pin always lands in a clean slot.
    func unpinTask(id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }),
              tasks[idx].pinnedRank != nil else { return }
        tasks[idx].pinnedRank = nil
        tasks[idx].modifiedAt = Date()
        store.upsert(tasks[idx], at: idx)
        // Re-number remaining pins.
        var pinned = tasks
            .enumerated()
            .compactMap { (storageIdx, t) -> (storageIdx: Int, rank: Int)? in
                guard let rank = t.pinnedRank else { return nil }
                return (storageIdx, rank)
            }
            .sorted { $0.rank < $1.rank }
        for (newRank, entry) in pinned.enumerated() where tasks[entry.storageIdx].pinnedRank != newRank {
            tasks[entry.storageIdx].pinnedRank = newRank
            tasks[entry.storageIdx].modifiedAt = Date()
            store.upsert(tasks[entry.storageIdx], at: entry.storageIdx)
        }
        NotificationCenter.default.post(name: Self.taskUpdated, object: id)
    }

    /// Drop every pin. Used by tests and by an "Unpin all" affordance if we
    /// add one later.
    func unpinAll() {
        var changed: [Int] = []
        for i in tasks.indices where tasks[i].pinnedRank != nil {
            tasks[i].pinnedRank = nil
            tasks[i].modifiedAt = Date()
            changed.append(i)
        }
        for i in changed {
            store.upsert(tasks[i], at: i)
        }
        if !changed.isEmpty {
            NotificationCenter.default.post(name: Self.taskUpdated, object: nil)
        }
    }

    /// Move `moved` to the very end of the active storage order.
    func moveTaskToEnd(id moved: String) {
        guard let fromIdx = tasks.firstIndex(where: { $0.id == moved }) else { return }
        let task = tasks.remove(at: fromIdx)
        tasks.append(task)
        store.reorder(fromIndex: fromIdx, tasks: tasks)
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
            store.delete(id:id)
        }
        store.reorder(fromIndex: firstRemovedIndex, tasks: tasks)
        for task in stale {
            NotificationCenter.default.post(name: Self.taskRemoved, object: task)
        }
    }

    // Persistence lives in `BacklogTaskStore` (production) or
    // `InMemoryBacklogTaskStore` (tests). The service stays focused on
    // orchestration: task lifecycle, notifications, CloudKit merge rules.

    /// Reload from disk after a CloudKit import, merge each row with its
    /// pre-import in-memory version via `BacklogTask.merged`, and write
    /// back any rows where the merge elevated a field the losing device
    /// needs to see (e.g. "remote said .pending but we had .done +
    /// completedAt"). The write-back is routed through `store.reconcile`
    /// so the service never touches SwiftData directly.
    private func reconcileAfterCloudImport() {
        let before = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        tasks = store.reconcile { disk in
            guard let local = before[disk.id] else { return disk }
            return BacklogTask.merged(local: local, remote: disk)
        }
        NotificationCenter.default.post(name: Self.taskUpdated, object: nil)
    }

    /// Full reconcile: align the persisted set to `tasks` exactly.
    /// Preserved as a safety net for tests and future bulk import paths;
    /// production mutations use the targeted `store.upsert` / `.delete` /
    /// `.reorder` helpers above.
    func saveAll() {
        store.replaceAll(with: tasks)
    }
}
