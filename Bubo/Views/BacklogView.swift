import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Backlog View

/// Inline backlog panel for the main screen.
/// Tasks are persistent and flow into the schedule.
///
/// Design (Birman):
/// - No modality: editing inline, no separate screen
/// - Data is precious: tasks persist until completed
/// - Undo instead of confirmation
/// - Meaningful grouping: by urgency and project
/// - Direct manipulation: inline editing of all properties
struct BacklogView: View {
    var backlogService: BacklogService
    var optimizerService: OptimizerService
    var reminderService: ReminderService
    /// Fired when the user taps the fullscreen-affordance in the Tasks
    /// header. The parent owns navigation state and pushes the fullscreen
    /// Backlog onto the popover stack.
    var onEnterFullscreen: (() -> Void)? = nil
    /// Fired for any reversible user action (uncomplete, unfreeze) so
    /// the parent can surface a unified undo toast — it owns `ToastState`.
    /// nil silently disables the toast; the action still runs.
    var onUndoableAction: ((_ message: String, _ undo: @escaping () -> Void) -> Void)? = nil
    /// Schedule the unscheduled backlog onto the calendar via the optimizer.
    /// Wired from `MenuBarView.runQuickAction(.scheduleBacklog,…)` and
    /// surfaced through SmartActions' Hard-overflow row.
    var onScheduleBacklog: (() async -> Void)? = nil
    /// Run the deadline-mode preset — SmartActions surfaces this when the
    /// overflow set contains urgent tasks.
    var onFocusOnDeadlines: (() async -> Void)? = nil
    /// Run an arbitrary `OptimizationRequest` — used by SmartActions to
    /// fire soft-suggestion candidates and `Plan day…` presets.
    var onRunRequest: ((OptimizationRequest, String) async -> Void)? = nil
    /// Open the command palette — SmartActions calm-state «More…» and
    /// the global `⌘K` shortcut both end up here.
    var onOpenPalette: (() -> Void)? = nil
    /// Cycle the just-applied scenario to a different index. Wired into
    /// `OptimizerService.switchToAppliedScenario(at:)`. Surfaces only when
    /// the GA returned ≥2 scenarios; nil = scenario picker is static dots.
    var onSwitchScenario: ((Int) -> Void)? = nil
    /// Bulk-lock today's events — SmartActions calm popover's
    /// «Lock today's events» quick action calls into this.
    var onLockTodaysEvents: (() -> Void)? = nil
    /// When true, the panel auto-expands on appear if tasks exist. Used
    /// in the empty-calendar state where tasks are the primary content.
    var autoExpand: Bool = false

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ReminderSettings.self) private var settings

    /// Two-state disclosure for the panel.
    /// Birman: один шеврон — два смысла («header only» / «with smart
    /// actions and tombstones»). The legacy `.expanded` mode survives in
    /// `TaskListExpansion` for compatibility but is unused here.
    @State private var expansion: TaskListExpansion = .collapsed
    /// Whether the "N completed today" tombstone is expanded. Collapsed
    /// by default so finished work doesn't crowd the panel.
    @State private var showCompletedToday: Bool = false
    /// Whether the frozen tombstone is expanded.
    @State private var showFrozen: Bool = false
    /// Smart-sort toggle in the header. Inert in the inline panel (no
    /// rows to sort here) but kept as state so the same `BacklogHeader`
    /// API satisfies inline + fullscreen.
    @State private var useSmartSort: Bool = false
    /// Urgent-only toggle in the header — same caveat as `useSmartSort`:
    /// inert inline, alive in the fullscreen surface.
    @State private var urgentOnlyFilter: Bool = false

    /// Persisted disclosure state. Only the user-facing `.collapsed` /
    /// `.compact` distinction survives across app launches.
    @AppStorage("BuboBacklogExpansionExpanded") private var persistedExpansionExpanded: Bool = false

    /// Single-line row height — used by the tombstone rows so they line
    /// up with the rhythm fullscreen rows used to set.
    static let compactRowHeight: CGFloat = 40

    /// Maximum height of the tombstone scroll area in the stripped
    /// inline panel. Big enough to surface 4–5 completed/frozen rows
    /// without scrolling, small enough that a long history can't
    /// push the timeline off-screen.
    static let inlineTombstonesMaxHeight: CGFloat = 180

    /// True when there's anything in the «recently undone» buckets to
    /// display. Drives both the panel-visibility gate and the
    /// tombstones section inside the panel.
    private var hasTombstones: Bool {
        !completedToday.isEmpty || !backlogService.frozen.isEmpty
    }

    /// All non-done, non-frozen tasks — the "real" active set used for
    /// totals, capacity math and onAppear heuristics. Not subject to the
    /// urgent-only UI filter, so the header counter doesn't lie about
    /// what's actually in the backlog.
    private var allActiveTasks: [BacklogTask] {
        BacklogLogic.activeTasks(backlogService.tasks)
    }

    /// Tasks visible in the list. Equals `allActiveTasks` unless the
    /// urgent-only filter or the active-project picker is engaged. Both
    /// are display-level filters — they do **not** scope the capacity
    /// ring (`pendingWorkloadMinutes` keeps reading `allActiveTasks`),
    /// so «one day vs the whole queue» остаётся главным сигналом, а
    /// проектный фокус работает поверх. Keeping the filters here
    /// (not in the service) means the storage order stays the user's
    /// canonical sequence.
    private var activeTasks: [BacklogTask] {
        var result = allActiveTasks
        if let project = activeProjectName {
            result = result.filter { ($0.context ?? "") == project }
        }
        if urgentOnlyFilter {
            result = result.filter { isUrgent($0) }
        }
        return result
    }

    /// Display name of the project the user is currently focused on (local
    /// Bubo project or Apple Reminders list), or `nil` for «All Tasks» /
    /// when the active project no longer exists. Resolved at read time so
    /// a rename in Reminders.app picks up on the next sync without a stale
    /// cached name.
    private var activeProjectName: String? {
        settings.activeProjectTitle(remindersService: AppleRemindersService.shared)
    }

    /// Urgent count shown in the header pill. Project-scoped: when picker
    /// has an active project, count only urgent tasks IN that project,
    /// иначе pill читался бы как «3 urgent», но клик уводил бы в пустой
    /// список (urgent живут в другом проекте). При «All Tasks» считаем
    /// глобально, как раньше.
    private var headerUrgentCount: Int {
        if let project = activeProjectName {
            return allActiveTasks.filter {
                ($0.context ?? "") == project && BacklogLogic.isUrgent($0)
            }.count
        }
        return backlogService.urgent(withinDays: 2).count
    }

    /// Tasks completed since local midnight. Powers the «N completed today»
    /// tombstone.
    private var completedToday: [BacklogTask] {
        BacklogLogic.completedToday(backlogService.tasks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Inline backlog is now a status-panel: counts + capacity
            // ring + adaptive SmartActions row + tombstones for undo.
            // Active task rows, the add-task input, and the drag
            // source all moved out — task creation lives on the
            // timeline (`SlotPickerPopover`) and editing/reordering
            // lives in the fullscreen backlog. Birman: «один экран
            // — одна работа», and the work this panel is hired for
            // is reading status, not editing tasks.
            if !allActiveTasks.isEmpty || hasTombstones {
                BacklogHeader(
                    mode: .inline(
                        expansion: $expansion,
                        onEnterFullscreen: onEnterFullscreen
                    ),
                    totalCount: allActiveTasks.count,
                    urgentCount: headerUrgentCount,
                    pendingMinutes: pendingWorkloadMinutes,
                    remainingWorkdayMinutes: remainingWorkdayMinutes,
                    optimizerService: optimizerService,
                    capacityRingTooltip: capacityRingTooltip,
                    useSmartSort: $useSmartSort,
                    urgentOnlyFilter: $urgentOnlyFilter
                )
                if expansion != .collapsed {
                    // SmartActions: overflow fix when over capacity,
                    // ranked soft suggestion when nothing is wrong
                    // but the engine has something to offer, or quiet
                    // `Plan day…` discovery when the day is calm.
                    smartActionsRow

                    // Tombstones (completed today / frozen) — kept in
                    // the inline panel so the user can undo a misclick
                    // without bouncing into fullscreen. Wrapped in a
                    // bounded scroll view so a long completed-today
                    // pile can't push the timeline off-screen.
                    if hasTombstones {
                        SkinSeparator()
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.top, DS.Spacing.xs)
                        ScrollView(.vertical, showsIndicators: true) {
                            tombstones
                        }
                        .frame(maxHeight: Self.inlineTombstonesMaxHeight)
                        .padding(.horizontal, DS.Spacing.sm)
                    }
                }
            }
        }
        .onAppear {
            // Restore the user's last disclosure choice.
            expansion = persistedExpansionExpanded ? .compact : .collapsed
            if autoExpand && !allActiveTasks.isEmpty {
                expansion = .compact
            }
            // If the user returns to a state with zero active tasks but
            // non-empty tombstones, auto-open to `.compact` so the
            // history stays reachable — otherwise the chevron is the
            // only clue anything survived.
            if allActiveTasks.isEmpty,
               hasTombstones,
               expansion == .collapsed {
                expansion = .compact
            }
        }
        .onChange(of: allActiveTasks.count) { _, newCount in
            // Same auto-open rule on live state changes: the last
            // active task got completed and we still have tombstones —
            // pop the panel open so the user sees what happened.
            if newCount == 0,
               hasTombstones,
               expansion == .collapsed {
                withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                    expansion = .compact
                }
            }
        }
        .onChange(of: expansion) { _, newValue in
            switch newValue {
            case .collapsed: persistedExpansionExpanded = false
            case .compact:   persistedExpansionExpanded = true
            case .expanded:  break
            }
        }
    }

    /// Single contextual row directly under the header that absorbs the
    /// four legacy optimizer entry points (SmartBanner, SpillOverMarker,
    /// QuickActions chip, PlanDayMenu) into one adaptive surface. Reads
    /// `BacklogLogic.capacityForecast` to pick hard / soft / calm rendering;
    /// see `SmartActions` for the resolution rules.
    @ViewBuilder
    private var smartActionsRow: some View {
        let plan = BacklogLogic.CapacitySectionPlan(
            orderedTasks: allActiveTasks,
            remainingWorkdayMinutes: remainingWorkdayMinutes
        )
        let forecast = BacklogLogic.capacityForecast(
            pendingMinutes: pendingWorkloadMinutes,
            workingHours: optimizerService.workingHours,
            workingDays: optimizerService.workingDays
        )

        SmartActions(
            forecast: forecast,
            overflowingCount: plan.overflowing.count,
            overflowMinutes: plan.overflowMinutes,
            overflowHasUrgent: plan.overflowHasUrgent,
            suggestion: optimizerService.suggestionEngine?.suggestion,
            shadowProposal: optimizerService.shadowProposal,
            recentApplied: optimizerService.lastAppliedRequest,
            onScheduleBacklog: { await onScheduleBacklog?() },
            onFocusOnDeadlines: { await onFocusOnDeadlines?() },
            onRunRequest: { request, label in
                await onRunRequest?(request, label)
            },
            onOpenPalette: { onOpenPalette?() },
            onSwitchScenario: onSwitchScenario,
            onLockTodaysEvents: onLockTodaysEvents,
            compact: true
        )
        .padding(.horizontal, DS.Spacing.sm)
        // Inline backlog is height-constrained — the row already pads
        // itself internally (`Spacing.xxs` in compact mode), so we add
        // no extra vertical air here. Was `Spacing.xs` on each side,
        // which doubled with the row's own padding and pushed the
        // task list out of view.
    }

    // MARK: - Capacity ring helpers

    /// Total scheduled minutes across all non-done, non-frozen tasks —
    /// the workload the user would need to fit into today's remaining hours.
    private var pendingWorkloadMinutes: Int {
        // Use `allActiveTasks` — capacity-vs-workday is about the total
        // backlog, not a UI-filtered subset. Otherwise toggling the urgent
        // filter would make the ring falsely turn green.
        allActiveTasks.reduce(0) { $0 + $1.durationMinutes }
    }

    /// Number of active tasks that don't fit in the remaining workday —
    /// drives the «· N don't fit» suffix on the capacity verdict so the
    /// reader doesn't have to subtract fits from the total. Computed off
    /// `allActiveTasks` (not the urgent-filtered view) for the same reason
    /// `pendingWorkloadMinutes` does — capacity is about the whole queue.
    private var overflowingTaskCount: Int {
        BacklogLogic.capacityPartition(
            allActiveTasks,
            remainingWorkdayMinutes: remainingWorkdayMinutes
        ).overflowing.count
    }

    /// Remaining minutes between "now" and the end of the working day.
    /// Clamped to zero past the workday so the ring stays at 100% after hours
    /// instead of going negative. Uses `OptimizerService.workingHours` — the
    /// same source of truth as the free-slot finder.
    private var remainingWorkdayMinutes: Int {
        BacklogLogic.remainingWorkdayMinutes(
            workingHours: optimizerService.workingHours,
            workingDays: optimizerService.workingDays
        )
    }

    private var capacityRingTooltip: String {
        let workload = pendingWorkloadMinutes
        let remaining = remainingWorkdayMinutes
        return "Backlog: \(DS.formatMinutes(workload)); remaining today: \(DS.formatMinutes(remaining))"
    }

    // The active-task list used to live here, between the SmartActions
    // row and the tombstones. It moved out: task creation is now a
    // timeline gesture (`SlotPickerPopover` on the «+» of any free
    // slot), and editing / reordering / completion happen in the
    // fullscreen backlog (chevron in the header). Inline panel = read
    // status, undo recent actions; nothing more.

    // MARK: - Tombstones

    /// Shared completed-today + frozen summary rows. Click on a filled
    /// checkmark restores a task, click on a snowflake unfreezes one;
    /// «Unfreeze all» batch-thaws.
    @ViewBuilder
    private var tombstones: some View {
        BacklogTombstones(
            completedToday: completedToday,
            frozen: backlogService.frozen,
            showCompleted: $showCompletedToday,
            showFrozen: $showFrozen,
            // Inline backlog rows have a leading drag-handle column, so we
            // ask the tombstone to reserve the same gutter and match the
            // 40pt active-row height — that's what keeps the checkmark
            // column lined up under the active list above.
            alignedLeadingGutter: true,
            minRowHeight: Self.compactRowHeight,
            onUncomplete: { task in uncompleteTask(task) },
            onUnfreezeOne: { task in unfreezeOneWithUndo(task) },
            onUnfreezeAll: { unfreezeAllWithUndo() }
        )
    }

    /// Restore a completed task to the pending list. Undo is the tombstone
    /// itself — if the user changes their mind again, the task is right there
    /// to re-complete.
    private func uncompleteTask(_ task: BacklogTask) {
        var restored = task
        restored.status = .pending
        restored.completedAt = nil
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.updateTask(restored)
        }
    }

    /// Unfreeze a single task with an undo toast that re-freezes on tap.
    private func unfreezeOneWithUndo(_ task: BacklogTask) {
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.unfreezeTask(id: task.id)
        }
        onUndoableAction?("Unfroze \u{201C}\(task.title)\u{201D}") { [backlogService] in
            backlogService.updateTask(snapshot)
            backlogService.freezeTask(id: snapshot.id)
        }
    }

    /// Batch-unfreeze every frozen task. Undo re-freezes by id so the toast
    /// reverses the operation cleanly even if the array shifts in between.
    private func unfreezeAllWithUndo() {
        let restoredIds = backlogService.frozen.map(\.id)
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.unfreezeAll()
        }
        onUndoableAction?("Unfroze \(restoredIds.count) task\(restoredIds.count == 1 ? "" : "s")") { [backlogService] in
            for id in restoredIds { backlogService.freezeTask(id: id) }
        }
    }

}

