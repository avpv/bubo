import Foundation

// MARK: - BacklogService mutations
//
// Every method that adds, edits, removes, completes, schedules, or
// reorders a backlog task lives here. Each path:
//   1. Mutates `tasks` (the in-memory mirror).
//   2. Persists the change through `store` (SwiftData in production,
//      `InMemoryBacklogTaskStore` in tests).
//   3. Posts the matching `NotificationCenter` event so observers
//      (`RemindersSyncService`, the menu bar timeline, the optimizer's
//      cache) can react.
//
// Notification payloads follow the contract documented on the
// `postTask*` helpers in `BacklogService.swift`:
//   - `taskAdded` / `taskUpdated` / `taskCompleted` / `taskScheduleChanged`
//     carry the task ID (`String`); `taskUpdated` may carry `nil` to
//     signal a bulk refresh.
//   - `taskRemoved` carries the full `BacklogTask` because downstream
//     observers need fields like `reminderCalendarItemId` after the row
//     is already gone from `tasks`.
//
// Extracted from `BacklogService.swift` so the queries surface and the
// CloudKit-import reconciliation in the main file aren't buried in the
// 300+ lines of mutation code.

extension BacklogService {

    // MARK: - Mutations

    func addTask(_ task: BacklogTask) {
        let index = tasks.count
        tasks.append(task)
        store.upsert(task, at: index)
        postTaskAdded(task.id)
    }

    func addTasks(_ newTasks: [BacklogTask]) {
        let baseIndex = tasks.count
        tasks.append(contentsOf: newTasks)
        for (offset, task) in newTasks.enumerated() {
            store.upsert(task, at: baseIndex + offset)
        }
        for task in newTasks {
            postTaskAdded(task.id)
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
        postTaskUpdated(incoming.id)
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
        postTaskRemoved(removed)
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
        postTaskCompleted(id)
    }

    /// Set aside a task without deleting it. The task leaves the active list
    /// and stops participating in optimization, but stays in storage under
    /// `frozen`. Complements delete (destructive) — Birman: «data is precious».
    func freezeTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .frozen
        // Drop schedule linkage so the calendar slot is freed.
        tasks[index].scheduledEventId = nil
        tasks[index].scheduledEventIds = []
        tasks[index].scheduledDate = nil
        store.upsert(tasks[index], at: index)
        postTaskUpdated(id)
        postTaskScheduleChanged(id)
    }

    /// Restore a frozen task to the backlog so it can be scheduled again.
    func unfreezeTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].status == .frozen else { return }
        tasks[index].status = .pending
        store.upsert(tasks[index], at: index)
        postTaskUpdated(id)
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
            postTaskUpdated(nil)
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
        postTaskScheduleChanged(id)
    }

    func unschedule(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .pending
        tasks[index].scheduledEventId = nil
        tasks[index].scheduledEventIds = []
        tasks[index].scheduledDate = nil
        store.upsert(tasks[index], at: index)
        postTaskScheduleChanged(id)
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

    /// «Roll today forward» — unschedule every task scheduled for today
    /// that hasn't been completed yet. Returns a snapshot of the
    /// affected tasks (pre-mutation) so the caller can offer undo.
    /// Different from `carryOverUnfinished`, which only fires once on
    /// startup for past-day leftovers; this is the explicit
    /// end-of-workday action surfaced via the «Roll forward» banner.
    @discardableResult
    func rollTodayForward(now: Date = Date()) -> [BacklogTask] {
        let cal = Calendar.current
        var snapshots: [BacklogTask] = []
        var changedIndexes: [Int] = []
        for i in tasks.indices {
            guard tasks[i].status == .scheduled,
                  let scheduled = tasks[i].scheduledDate,
                  cal.isDate(scheduled, inSameDayAs: now)
            else { continue }
            snapshots.append(tasks[i])
            tasks[i].status = .pending
            tasks[i].scheduledEventId = nil
            tasks[i].scheduledEventIds = []
            tasks[i].scheduledDate = nil
            changedIndexes.append(i)
        }
        for i in changedIndexes {
            store.upsert(tasks[i], at: i)
        }
        if !changedIndexes.isEmpty {
            for snapshot in snapshots {
                postTaskScheduleChanged(snapshot.id)
            }
        }
        return snapshots
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

    /// Move `moved` to the very end of the active storage order.
    func moveTaskToEnd(id moved: String) {
        guard let fromIdx = tasks.firstIndex(where: { $0.id == moved }) else { return }
        let task = tasks.remove(at: fromIdx)
        tasks.append(task)
        store.reorder(fromIndex: fromIdx, tasks: tasks)
    }

}
