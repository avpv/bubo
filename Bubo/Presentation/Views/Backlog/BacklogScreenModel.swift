import SwiftUI
import BuboDomain
import BuboOptimizer

// MARK: - Backlog screen model
//
// Stage 2 of UI_REFACTORING.md: one observable model owns the backlog
// screen's session state, every derived computation, and every data
// mutation. `BacklogFullscreenView` is composition only — it reads the
// model, hands bindings to subviews, and keeps just what genuinely
// belongs to the view layer (FocusState, navigation closures).
//
// Math stays delegated to the pure `BacklogLogic` helpers; the model is
// the glue that was previously smeared across the view body and three
// `BacklogFullscreenView+*` extension files.

@MainActor
@Observable
final class BacklogScreenModel {

    // MARK: Dependencies

    @ObservationIgnored private let backlogService: BacklogService
    @ObservationIgnored private let optimizerService: OptimizerService
    @ObservationIgnored private let settings: ReminderSettings

    /// Undo-toast hook from the host (MenuBarView's toast pipeline).
    @ObservationIgnored var onUndoable: ((_ message: String, _ undo: @escaping () -> Void) -> Void)?

    /// Mirrored from the view's `accessibilityReduceMotion` environment —
    /// the model drives `withAnimation` for its mutations, and motion
    /// awareness must follow the live setting.
    @ObservationIgnored var reduceMotion: Bool = false

    init(
        backlogService: BacklogService,
        optimizerService: OptimizerService,
        settings: ReminderSettings
    ) {
        self.backlogService = backlogService
        self.optimizerService = optimizerService
        self.settings = settings
    }

    // MARK: Session state

    /// One-of-N «view as…» filter. nil = "All".
    var smartFilter: BacklogLogic.SmartFilter? = nil
    /// Re-orders the list by `BacklogLogic.smartScore` instead of user
    /// drag order. Session-local.
    var useSmartSort: Bool = false
    var showCompletedToday: Bool = false
    var showFrozen: Bool = false

    /// IDs in the multi-select set. See `selectionMode` for the mode flag —
    /// decoupled so deselecting the last row doesn't snap the toolbar away.
    var selectedTaskIds: Set<String> = []
    var selectionMode: Bool = false

    /// Draft for the inline `+ Add task…` field.
    var newTaskTitle: String = ""
    /// Cached parse of `newTaskTitle` — updated by the view's onChange so
    /// the title/duration pair is computed once per keystroke.
    var parsedNewTaskTitle: (cleaned: String, durationMinutes: Int?) = ("", nil)

    /// Task whose deadline is being edited via «Set deadline…».
    var deadlinePickerTask: BacklogTask? = nil

    // MARK: Derived — task sets

    /// Display name of the project the user is focused on via the header's
    /// project picker; nil for «All Tasks».
    var activeProjectName: String? {
        settings.activeProjectTitle(remindersService: AppleRemindersService.shared)
    }

    /// All active tasks (without filters) — the common basis for capacity.
    var activeTasks: [BacklogTask] {
        BacklogLogic.activeTasks(backlogService.tasks)
    }

    /// Active set after the project picker and the smart-filter strip.
    /// Capacity keeps reading the unfiltered `activeTasks`: the tab narrows
    /// what is shown, not the size of the day.
    var activeFiltered: [BacklogTask] {
        var result = activeTasks
        if let project = activeProjectName {
            result = result.filter { ($0.context ?? "") == project }
        }
        if let smart = smartFilter {
            result = result.filter { BacklogLogic.matchesSmartFilter($0, filter: smart) }
        }
        return result
    }

    /// Pre-computed badges for the smart-filter chip row.
    var smartFilterCounts: [BacklogLogic.SmartFilter: Int] {
        BacklogLogic.smartFilterCounts(activeTasks)
    }

    /// Tasks rendered in the list — user order or smart-sort.
    var visibleTasks: [BacklogTask] {
        useSmartSort ? BacklogLogic.smartSorted(activeFiltered) : activeFiltered
    }

    /// Tasks completed since local midnight (tombstones).
    var completedToday: [BacklogTask] {
        BacklogLogic.completedToday(backlogService.tasks)
    }

    var frozen: [BacklogTask] {
        backlogService.frozen
    }

    /// Urgent count, project-scoped when a project is active so the pill
    /// never leads to an empty list.
    var urgentCount: Int {
        if let project = activeProjectName {
            return activeTasks.filter {
                ($0.context ?? "") == project && BacklogLogic.isUrgent($0)
            }.count
        }
        return backlogService.urgent(withinDays: 2).count
    }

    // MARK: Derived — capacity

    /// Total queue load in minutes (unfiltered).
    var pendingWorkloadMinutes: Int {
        activeTasks.reduce(0) { $0 + $1.durationMinutes }
    }

    /// `.pending` (unscheduled) count — drives the header «Plan N» pill.
    var pendingUnscheduledCount: Int {
        backlogService.pending.count
    }

    /// UX_AUDIT F10 (decided 2026-07-05): the day's remaining minutes —
    /// and every verdict derived from them (ring, «N don't fit»,
    /// partition) — read the CLOCK only. `workingDays` stays an
    /// auto-placement rule for the GA (see `proposedSlots` below, which
    /// keeps it: the machine still won't PROPOSE an off-day slot).
    var remainingWorkdayMinutes: Int {
        // Today's per-day override wins over the global default —
        // the ring must agree with the timeline's window for today.
        BacklogLogic.remainingWorkdayMinutes(
            workingHours: optimizerService.workingHours(on: Date())
        )
    }

    /// Count of active tasks that don't fit in the remaining workday.
    var overflowingTaskCount: Int {
        BacklogLogic.capacityPartition(
            activeTasks,
            remainingWorkdayMinutes: remainingWorkdayMinutes
        ).overflowing.count
    }

    var capacityRingTooltip: String {
        "Backlog: \(DS.formatMinutes(pendingWorkloadMinutes)); remaining today: \(DS.formatMinutes(remainingWorkdayMinutes))"
    }

    /// Fits / overflow partition of the visible set, in render order.
    var sectionPlan: BacklogLogic.CapacitySectionPlan {
        BacklogLogic.CapacitySectionPlan(
            orderedTasks: visibleTasks,
            remainingWorkdayMinutes: remainingWorkdayMinutes
        )
    }

    /// Per-task proposed start times for overflowing rows — GA shadow
    /// proposal wins over the naive projection wherever both exist.
    var proposedSlots: [String: Date] {
        let plan = sectionPlan
        let shadowSlots = BacklogLogic.proposedSlotsFromShadow(optimizerService.shadowProposal)
        let naiveSlots = BacklogLogic.naiveProposedSlots(
            overflowingTasks: plan.overflowing,
            workingHours: optimizerService.workingHours,
            workingDays: optimizerService.workingDays
        )
        return naiveSlots.merging(shadowSlots) { _, shadow in shadow }
    }

    // MARK: Derived — selection & reorder gates

    /// Selected tasks resolved against the live store at call time, in
    /// render order, so deletions mid-flow never leave dangling IDs.
    var selectedTasks: [BacklogTask] {
        let ids = selectedTaskIds
        guard !ids.isEmpty else { return [] }
        return visibleTasks.filter { ids.contains($0.id) }
    }

    func canMoveUp(_ task: BacklogTask) -> Bool {
        visibleTasks.first?.id != task.id
            && visibleTasks.contains(where: { $0.id == task.id })
    }

    func canMoveDown(_ task: BacklogTask) -> Bool {
        visibleTasks.last?.id != task.id
            && visibleTasks.contains(where: { $0.id == task.id })
    }

    // MARK: Mutations — add / complete / delete / freeze

    /// Create a task from the inline draft. Duration priority: explicit
    /// parse > machine verb-guess > user default. Stamps the active
    /// project on `context` so the task lands in the current view.
    func addTask() {
        let parsed = parsedNewTaskTitle
        let title = parsed.cleaned
        guard !title.isEmpty else { return }

        let duration = parsed.durationMinutes
            ?? BacklogTitleParser.guessDuration(for: title)
            ?? optimizerService.defaultTaskDurationMinutes

        let task = BacklogTask(
            title: title,
            durationMinutes: duration,
            priority: .medium,
            context: activeProjectName
        )
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.addTask(task)
        }
        clearDraft()
    }

    func clearDraft() {
        newTaskTitle = ""
        parsedNewTaskTitle = ("", nil)
    }

    func complete(_ task: BacklogTask) {
        // The checkbox press already fired its own haptic; hot-key
        // completion fires one before delegating here.
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.entrance, reduceMotion: reduceMotion)) {
            backlogService.completeTask(id: task.id)
        }
        onUndoable?("Completed \u{201C}\(task.title)\u{201D}") { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    func uncomplete(_ task: BacklogTask) {
        var restored = task
        restored.status = .pending
        restored.completedAt = nil
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.updateTask(restored)
        }
    }

    func delete(_ task: BacklogTask) {
        let originalIndex = backlogService.indexOfTask(id: task.id)
        _ = backlogService.removeTask(id: task.id)
        onUndoable?("\u{201C}\(task.title)\u{201D} deleted") { [backlogService] in
            backlogService.restoreTask(task, at: originalIndex)
        }
    }

    func freeze(_ task: BacklogTask) {
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.freezeTask(id: task.id)
        }
        onUndoable?("Froze \u{201C}\(task.title)\u{201D}") { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    func unfreezeOneWithUndo(_ task: BacklogTask) {
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.unfreezeTask(id: task.id)
        }
        onUndoable?("Unfroze \u{201C}\(task.title)\u{201D}") { [backlogService] in
            backlogService.updateTask(snapshot)
            backlogService.freezeTask(id: snapshot.id)
        }
    }

    func unfreezeAllWithUndo() {
        let restoredIds = backlogService.frozen.map(\.id)
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.unfreezeAll()
        }
        onUndoable?("Unfroze \(restoredIds.count)\u{00A0}task\(restoredIds.count == 1 ? "" : "s")") { [backlogService] in
            for id in restoredIds { backlogService.freezeTask(id: id) }
        }
    }

    // MARK: Mutations — task fields

    func updateTaskDeadline(task: BacklogTask, to newDeadline: Date?) {
        let snapshot = task
        var updated = task
        updated.deadline = newDeadline
        guard updated != snapshot else { return }
        withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
            backlogService.updateTask(updated)
        }
        let label: String
        if let deadline = newDeadline {
            let formatted = deadline.formatted(date: .abbreviated, time: .shortened)
            label = "Set deadline on \u{201C}\(task.title)\u{201D} to \(formatted)"
        } else {
            label = "Cleared deadline on \u{201C}\(task.title)\u{201D}"
        }
        onUndoable?(label) { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    /// Toggle urgent state via today-end deadline.
    func toggleUrgent(_ task: BacklogTask) {
        let snapshot = task
        var updated = task
        let calendar = Calendar.current
        if let deadline = task.deadline, calendar.isDateInToday(deadline) {
            updated.deadline = nil
        } else {
            updated.deadline = calendar.date(
                bySettingHour: 23, minute: 59, second: 0, of: Date()
            ) ?? Date()
        }
        withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
            backlogService.updateTask(updated)
        }
        let label = updated.deadline == nil
            ? "Cleared urgent on \u{201C}\(task.title)\u{201D}"
            : "Marked \u{201C}\(task.title)\u{201D} urgent"
        onUndoable?(label) { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    /// Push a task's deadline forward by `days`. Never-dated rows anchor
    /// at start-of-today + N days so «snooze» has a concrete meaning.
    func snoozeDeadline(_ task: BacklogTask, byDays days: Int) {
        var updated = task
        let cal = Calendar.current
        let base = task.deadline ?? cal.startOfDay(for: Date())
        if let pushed = cal.date(byAdding: .day, value: days, to: base) {
            updated.deadline = pushed
            backlogService.updateTask(updated)
        }
    }

    func setPreferredPeriod(_ period: Period?, on task: BacklogTask) {
        var updated = task
        updated.preferredPeriod = period
        backlogService.updateTask(updated)
    }

    // MARK: Mutations — selection

    /// Toggle membership in the bulk-action set; the first pick flips
    /// `selectionMode` on so every checkbox switches mode at once.
    func toggleSelection(_ task: BacklogTask) {
        Haptics.tap()
        withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
            if selectedTaskIds.contains(task.id) {
                selectedTaskIds.remove(task.id)
            } else {
                selectedTaskIds.insert(task.id)
                selectionMode = true
            }
        }
    }

    func exitSelection() {
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            selectedTaskIds.removeAll()
            selectionMode = false
        }
    }

    /// Drop selection IDs that left the active set (completed externally,
    /// synced away); auto-clear a smart filter whose count dried up.
    /// Called by the view's onChange over the active count.
    func pruneStaleSelection() {
        if !selectedTaskIds.isEmpty {
            let liveIds = Set(activeTasks.map(\.id))
            selectedTaskIds.formIntersection(liveIds)
        }
        if let smart = smartFilter, (smartFilterCounts[smart] ?? 0) == 0 {
            smartFilter = nil
        }
    }

    // MARK: Mutations — bulk

    /// Push every selected task's deadline forward by `days` as one undo unit.
    func bulkDefer(days: Int) {
        let snapshots = selectedTasks
        guard !snapshots.isEmpty else { return }
        Haptics.tap()
        let cal = Calendar.current
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            for task in snapshots {
                var updated = task
                let base = task.deadline ?? cal.startOfDay(for: Date())
                if let pushed = cal.date(byAdding: .day, value: days, to: base) {
                    updated.deadline = pushed
                    backlogService.updateTask(updated)
                }
            }
        }
        exitSelection()
        let label = "Deferred \(snapshots.count)\u{00A0}task\(snapshots.count == 1 ? "" : "s") by \(days)\u{00A0}day\(days == 1 ? "" : "s")"
        onUndoable?(label) { [backlogService] in
            for snapshot in snapshots {
                backlogService.updateTask(snapshot)
            }
        }
    }

    func bulkFreeze() {
        let snapshots = selectedTasks
        guard !snapshots.isEmpty else { return }
        Haptics.tap()
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            for task in snapshots {
                backlogService.freezeTask(id: task.id)
            }
        }
        exitSelection()
        let label = "Froze \(snapshots.count)\u{00A0}task\(snapshots.count == 1 ? "" : "s")"
        onUndoable?(label) { [backlogService] in
            for snapshot in snapshots {
                backlogService.updateTask(snapshot)
                backlogService.unfreezeTask(id: snapshot.id)
            }
        }
    }

    /// Delete the selected set as one undoable batch; undo restores each
    /// task at its original index so drag-order survives the round-trip.
    func bulkDelete() {
        let snapshots = selectedTasks
        guard !snapshots.isEmpty else { return }
        Haptics.tap()
        let indexes: [(BacklogTask, Int?)] = snapshots.map { ($0, backlogService.indexOfTask(id: $0.id)) }
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            for task in snapshots {
                _ = backlogService.removeTask(id: task.id)
            }
        }
        exitSelection()
        let label = "Deleted \(snapshots.count)\u{00A0}task\(snapshots.count == 1 ? "" : "s")"
        onUndoable?(label) { [backlogService] in
            // Restore in original-index order so earlier rows land first
            // and keep the storage sequence consistent.
            for (task, index) in indexes.sorted(by: { ($0.1 ?? .max) < ($1.1 ?? .max) }) {
                backlogService.restoreTask(task, at: index)
            }
        }
    }

    // MARK: Mutations — reorder

    /// Reorder by ±1 slot via keyboard / context menu. Honours user-order
    /// only; in smart-sort mode the call still mutates storage order.
    func moveTask(_ task: BacklogTask, by delta: Int) {
        let ordered = visibleTasks
        guard let current = ordered.firstIndex(where: { $0.id == task.id }) else { return }
        let target = current + delta
        guard ordered.indices.contains(target) else { return }
        let targetId = ordered[target].id

        let previousIndex = backlogService.indexOfTask(id: task.id)
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            if delta < 0 {
                backlogService.moveTask(id: task.id, before: targetId)
            } else if target + 1 < ordered.count {
                backlogService.moveTask(id: task.id, before: ordered[target + 1].id)
            } else {
                backlogService.moveTaskToEnd(id: task.id)
            }
        }

        let taskId = task.id
        onUndoable?("Reordered \u{201C}\(task.title)\u{201D}") { [backlogService] in
            guard let previousIndex,
                  let current = backlogService.tasks.first(where: { $0.id == taskId })
            else { return }
            _ = backlogService.removeTask(id: taskId)
            backlogService.restoreTask(current, at: previousIndex)
        }
    }

    func moveTaskToEdge(_ task: BacklogTask, toTop: Bool) {
        let previousIndex = backlogService.indexOfTask(id: task.id)
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            if toTop {
                if let firstVisible = visibleTasks.first, firstVisible.id != task.id {
                    backlogService.moveTask(id: task.id, before: firstVisible.id)
                }
            } else {
                backlogService.moveTaskToEnd(id: task.id)
            }
        }
        let taskId = task.id
        onUndoable?("Moved \u{201C}\(task.title)\u{201D} to \(toTop ? "top" : "bottom")") { [backlogService] in
            guard let previousIndex,
                  let current = backlogService.tasks.first(where: { $0.id == taskId })
            else { return }
            _ = backlogService.removeTask(id: taskId)
            backlogService.restoreTask(current, at: previousIndex)
        }
    }

    /// Drop one task onto another to reorder; cross-context drops adopt
    /// the target's context (otherwise grouping would undo the move).
    func handleReorderDrop(dropped: BacklogTaskDrag, target targetTask: BacklogTask) {
        let targetId = targetTask.id
        guard dropped.taskId != targetId,
              let originalTask = backlogService.tasks.first(where: { $0.id == dropped.taskId }),
              backlogService.tasks.contains(where: { $0.id == targetId }),
              let target = backlogService.tasks.first(where: { $0.id == targetId })
        else { return }

        let previousIndex = backlogService.indexOfTask(id: originalTask.id)
        let previousContext = originalTask.context
        let contextChanged = originalTask.context != target.context

        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            if contextChanged {
                var updated = originalTask
                updated.context = target.context
                backlogService.updateTask(updated)
            }
            backlogService.moveTask(id: originalTask.id, before: targetId)
        }

        let taskId = originalTask.id
        let originalSnapshot = originalTask
        onUndoable?(
            contextChanged
                ? "Moved \u{201C}\(originalTask.title)\u{201D} to \(target.context ?? "No project")"
                : "Reordered \u{201C}\(originalTask.title)\u{201D}"
        ) { [backlogService] in
            guard var current = backlogService.tasks.first(where: { $0.id == taskId }) else {
                backlogService.restoreTask(originalSnapshot, at: previousIndex)
                return
            }
            current.context = previousContext
            backlogService.updateTask(current)
            if let previousIndex {
                _ = backlogService.removeTask(id: taskId)
                backlogService.restoreTask(current, at: previousIndex)
            }
        }
    }
}
