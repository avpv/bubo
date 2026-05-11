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

    /// Age threshold (days) after which a pending task is considered stale —
    /// surfaced by `staleTasks` and pruned by `dropStaleTasks`.
    static let staleTaskThresholdDays = 14

    /// Date before which a pending task counts as stale. Computed against
    /// the current wall clock so callers don't drift apart.
    static var staleTaskCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -staleTaskThresholdDays, to: Date()) ?? Date()
    }

    // `tasks` setter is internal (was `private(set)`) so the
    // `BacklogService+Mutations` sibling file can write to it without
    // routing every mutation through a delegating method. External
    // consumers should still treat the array as read-only — every write
    // path is named `addTask`, `removeTask`, `updateTask`, etc.
    var tasks: [BacklogTask] = []

    /// Backlog persistence, isolated behind a protocol so tests can swap
    /// in `InMemoryBacklogTaskStore` without a SwiftData container. The
    /// production path wires in `BacklogTaskStore`. Internal so the
    /// `+Mutations` sibling file can call `store.upsert`/`replaceAll`.
    let store: any BacklogTaskStoring
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

    // MARK: - Notification posting
    //
    // Centralised wrappers around `NotificationCenter.default.post` so the
    // mutation methods read like a description of *what* changed instead of
    // a description of *how* observers are notified. Payload contract:
    //   - `taskAdded` / `taskUpdated` / `taskCompleted` / `taskScheduleChanged`
    //     carry the task ID (`String`); `taskUpdated` may carry `nil` to
    //     signal a bulk refresh that doesn't fit a single ID.
    //   - `taskRemoved` carries the full `BacklogTask` object because
    //     downstream observers need fields like `reminderCalendarItemId`
    //     for external cleanup, and the task is already gone from `tasks`
    //     by the time the notification fires.

    func postTaskAdded(_ id: String) {
        NotificationCenter.default.post(name: Self.taskAdded, object: id)
    }

    func postTaskUpdated(_ id: String?) {
        NotificationCenter.default.post(name: Self.taskUpdated, object: id)
    }

    func postTaskRemoved(_ task: BacklogTask) {
        NotificationCenter.default.post(name: Self.taskRemoved, object: task)
    }

    func postTaskCompleted(_ id: String) {
        NotificationCenter.default.post(name: Self.taskCompleted, object: id)
    }

    func postTaskScheduleChanged(_ id: String) {
        NotificationCenter.default.post(name: Self.taskScheduleChanged, object: id)
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

    /// Tasks pending for longer than `staleTaskThresholdDays`.
    var staleTasks: [BacklogTask] {
        let cutoff = Self.staleTaskCutoff
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

    // MARK: - Persistence (SwiftData — single shared ModelContainer)

    func dropStaleTasks() {
        let cutoff = Self.staleTaskCutoff
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
            postTaskRemoved(task)
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
        postTaskUpdated(nil)
    }

    /// Full reconcile: align the persisted set to `tasks` exactly.
    /// Preserved as a safety net for tests and future bulk import paths;
    /// production mutations use the targeted `store.upsert` / `.delete` /
    /// `.reorder` helpers above.
    func saveAll() {
        store.replaceAll(with: tasks)
    }
}
