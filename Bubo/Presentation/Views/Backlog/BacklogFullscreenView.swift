import SwiftUI
import BuboDomain
import BuboOptimizer

// MARK: - Backlog Fullscreen View

/// Full-screen Backlog view that lives inside the popover navigation stack.
/// Reachable via the fullscreen-affordance button in `BacklogView`'s header.
///
/// Visually it reads as **one stream** from the popover header down to the
/// last row: rules (header summary + smart-actions + filter chips) and
/// evidence (the task list) share the same flat surface, separated by a
/// single skin-aware hairline. The inline Tasks card on the main view keeps
/// its rounded chrome (a small object inside a busy popover); at fullscreen
/// scale, the whole list IS the object, so a separate card around the
/// rules would only fragment it. Birman: one object — one form, but the
/// form is dictated by scale.
///
/// Design:
/// - Full-size Backlog: shows the entire active list in
///   user order (or in smart-sort if the toggle is on).
///   There are no separate «modes» — it's just the same tasks card as
///   on the main screen, but at full popover size. Birman: one action — one form;
///   a mode-switcher inside the card only confused things.
/// - Urgent filter, smart-sort, drag-reorder, keyboard reorder —
///   everything available in the inline BacklogView is available here too.
/// - The list itself stays inline-editable: complete with a tap, edit by
///   pushing the same `EditTaskView` the backlog uses, undo via toast.
/// - Inline `+ Add task…` field at the bottom — the empty state must not
///   be a dead end; you can add a task right from here.
/// - Completed-today / frozen tombstones — the same residents as in the
///   inline Backlog, so today's history isn't lost when transitioning
///   to fullscreen.
/// - Hot-keys 1–9 — quick completion of the Nth visible task. This is an
///   addition over the inline Backlog (where digits are occupied by normal
///   input in the add-field), but it's appropriate for fullscreen mode:
///   hands are already on the keyboard.
struct BacklogFullscreenView: View {
    var backlogService: BacklogService
    var optimizerService: OptimizerService
    /// Calendar event source — surfaced for parity with the inline backlog;
    /// reserved for future cross-context affordances inside fullscreen.
    var reminderService: ReminderService
    var onExit: () -> Void
    var onEditTask: (BacklogTask) -> Void
    /// Same shape as `BacklogView.onCreateTaskWithDetails`: open the
    /// compact creation form pre-filled with whatever the user typed.
    /// Triggered by ⇧↩ / the trailing "›" affordance.
    var onCreateTaskWithDetails: ((_ prefillTitle: String, _ prefillDuration: Int?) -> Void)? = nil
    var onUndoableAction: ((_ message: String, _ undo: @escaping () -> Void) -> Void)? = nil
    /// Schedule the unscheduled backlog onto the calendar via the optimizer.
    /// Async so the spill-over marker can show a loading spinner inline
    /// during the run. Wired from `MenuBarView.runQuickAction(.scheduleBacklog,…)`.
    var onScheduleBacklog: (() async -> Void)? = nil
    /// Run the deadline-mode preset. Surfaces as the conditional second
    /// action-link in the spill-over marker when overflow contains urgent
    /// tasks. Wired from `MenuBarView.runQuickAction(.deadlineMode,…)`.
    var onFocusOnDeadlines: (() async -> Void)? = nil
    /// Run an arbitrary `OptimizationRequest` — used by `SmartActions` to
    /// fire soft-suggestion candidates and `Plan day…` presets through the
    /// same `runQuickAction` helper that drives the hard-overflow path.
    var onRunRequest: ((OptimizationRequest, String) async -> Void)? = nil
    /// Per-task scope optimizer entry — see `BacklogView.onScheduleTask`.
    /// Surfaces «Find a slot now» in the row context menu.
    var onScheduleTask: ((BacklogTask) -> Void)? = nil
    /// «Show me other slots» — runs the optimizer in scope of one
    /// task and returns N scenarios WITHOUT applying. Wired into the
    /// per-row Schedule button's ⌥-click via `BacklogTaskRow`.
    /// Returning an empty list is treated as «no alternatives, fall
    /// back to the default commit».
    var onLoadAlternativesForTask: ((BacklogTask) async -> [ScheduleScenario])? = nil
    /// Commit a previewed alternative scenario — host routes it through
    /// `OptimizerService.applyPreviewedScenario` so undo and learner
    /// bookkeeping match the standard apply path.
    var onPickAlternativeScenario: ((ScheduleScenario) -> Void)? = nil
    /// See `BacklogView.onSplitTask` — same handler routed through.
    var onSplitTask: ((BacklogTask) -> Void)? = nil
    /// Open the command palette — `SmartActions` calm-state `More…` and
    /// the global `⌘K` shortcut both end up here.
    var onOpenPalette: (() -> Void)? = nil
    /// Open the command palette seeded with a single task (per-task scope
    /// optimizer entry — context menu's «Reschedule…» on a row).
    var onRescheduleTask: ((BacklogTask) -> Void)? = nil

    @Environment(\.activeSkin) var skin
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(ReminderSettings.self) var settings

    /// Hot-keys are bound to the first N visible rows. 9 covers the digit
    /// keyboard 1…9; tasks beyond that need scrolling and a click. Same
    /// «keyboard-first completion» idea as Things and Linear.
    static let maxHotKeyTasks = 9

    @State var newTaskTitle = ""
    /// Cached parse result for `newTaskTitle`. Updated from `onChange` so
    /// the title/duration pair is computed once per keystroke.
    @State var parsedNewTaskTitle: (cleaned: String, durationMinutes: Int?) = ("", nil)
    @FocusState var isInputFocused: Bool
    /// Row-level keyboard focus, mirroring BacklogView. `nil` when the input
    /// field owns focus instead. Driven by ↑/↓ between rows; ⌘↑/↓ reorders.
    @FocusState var focusedTaskId: String?

    @State var showCompletedToday: Bool = false
    @State var showFrozen: Bool = false

    /// One-of-N "view as…" filter at the top of the fullscreen backlog,
    /// borrowed from Apple Reminders' Today / Scheduled / Flagged cards.
    /// nil = "All".
    @State var smartFilter: BacklogLogic.SmartFilter? = nil
    /// Smart-sort toggle — re-orders the list by `BacklogLogic.smartScore`
    /// instead of user drag order. Session-local.
    @State var useSmartSort: Bool = false

    /// Task whose deadline is currently being edited via the row's
    /// «Set deadline…» context-menu item. Mirrors `BacklogView` so both
    /// modes host the same inline picker.
    @State var deadlinePickerTask: BacklogTask? = nil

    /// IDs of tasks currently in the multi-select set. When non-empty,
    /// the bulk-action toolbar at the bottom replaces the add-task
    /// field, and each row's leading checkbox toggles set membership
    /// instead of completing the task. Empty + `selectionMode == false`
    /// is the default «browse» state. Birman: the rule is an object
    /// on the screen — the set IS the toolbar, not a hidden mode.
    @State var selectedTaskIds: Set<String> = []

    /// True while the user is curating a bulk-action set. Decoupled
    /// from `selectedTaskIds.isEmpty` so the user can deselect the
    /// last row without instantly snapping out of the mode (the
    /// toolbar stays visible with a «select more, or hit Done»
    /// affordance). Cleared on Esc / «Done» / page exit.
    @State var selectionMode: Bool = false

    /// All active tasks (without urgent filters etc.) — the common basis for
    /// computing the capacity ring (which shows the total queue load, not
    /// a filtered subset).
    private var activeTasks: [BacklogTask] {
        BacklogLogic.activeTasks(backlogService.tasks)
    }

    /// Active set after the smart-filter tab strip. Capacity
    /// (`pendingWorkloadMinutes`) keeps reading the unfiltered
    /// `activeTasks`, so the tab narrows what is shown, but not
    /// the size of the day.
    private var activeFiltered: [BacklogTask] {
        var result = activeTasks
        if let project = activeProjectName {
            result = result.filter { ($0.context ?? "") == project }
        }
        if let smart = smartFilter {
            result = result.filter {
                BacklogLogic.matchesSmartFilter($0, filter: smart)
            }
        }
        return result
    }

    /// Pre-computed badges for the smart-filter chip row. One scan over
    /// the active set instead of one per chip.
    private var smartFilterCounts: [BacklogLogic.SmartFilter: Int] {
        BacklogLogic.smartFilterCounts(activeTasks)
    }

    /// Display name of the project the user is currently focused on via
    /// the header's project picker — local Bubo project or Apple Reminders
    /// list, `nil` for «All Tasks». Same helper as in inline `BacklogView`
    /// — both modes read the active project with one formula, settings-driven,
    /// so toggling synchronously affects both.
    var activeProjectName: String? {
        settings.activeProjectTitle(remindersService: AppleRemindersService.shared)
    }

    /// Tasks rendered in the list. User order (or smart-sort,
    /// if the toggle is on), plus the urgent-only filter. Parallel to the
    /// inline BacklogView — the same mental set of tasks, just at full
    /// popover size.
    var visibleTasks: [BacklogTask] {
        useSmartSort ? BacklogLogic.smartSorted(activeFiltered) : activeFiltered
    }

    /// Tasks completed since local midnight. Same data source as BacklogView's
    /// tombstone — keeps «done today» accessible inside fullscreen mode.
    private var completedToday: [BacklogTask] {
        BacklogLogic.completedToday(backlogService.tasks)
    }

    /// Number of urgent tasks in the active set — drives both the urgent
    /// filter pill (visibility + label) and the auto-disengage rule when
    /// the set dries up.
    private var urgentCount: Int {
        // Project-scoped: with an active project selected, the pill reads
        // as «urgent in this project» rather than globally, otherwise a
        // click would lead to an empty list (urgent lives in another project).
        if let project = activeProjectName {
            return activeTasks.filter {
                ($0.context ?? "") == project && BacklogLogic.isUrgent($0)
            }.count
        }
        return backlogService.urgent(withinDays: 2).count
    }

    /// Total scheduled minutes across the entire active queue — workload
    /// the user would still need to fit. Used by the capacity ring; intentional
    /// difference from `totalMinutes` (which sums only the visible set).
    private var pendingWorkloadMinutes: Int {
        activeTasks.reduce(0) { $0 + $1.durationMinutes }
    }

    /// Number of `.pending` (unscheduled) tasks. Drives the «Plan N»
    /// header pill — `activeTasks` includes already-scheduled rows, so
    /// summing that would make the pill claim work it can't take on.
    private var pendingUnscheduledCount: Int {
        backlogService.pending.count
    }

    /// Remaining minutes between now and the end of the working day.
    private var remainingWorkdayMinutes: Int {
        BacklogLogic.remainingWorkdayMinutes(
            workingHours: optimizerService.workingHours,
            workingDays: optimizerService.workingDays
        )
    }

    /// Count of active tasks that don't fit in the remaining workday.
    /// Drives the «· N don't fit» suffix on the capacity verdict so the
    /// user reads the overflow count directly instead of subtracting.
    private var overflowingTaskCount: Int {
        BacklogLogic.capacityPartition(
            activeTasks,
            remainingWorkdayMinutes: remainingWorkdayMinutes
        ).overflowing.count
    }

    private var capacityRingTooltip: String {
        "Backlog: \(DS.formatMinutes(pendingWorkloadMinutes)); remaining today: \(DS.formatMinutes(remainingWorkdayMinutes))"
    }

    /// True when the day can no longer absorb the queue (overflow or
    /// after-hours). Gates the SmartActions row — the only state where a
    /// contextual fix verb earns a band of its own. The calm/soft states
    /// are covered by the header's persistent «Plan N» pill.
    private var capacityForecastIsHard: Bool {
        switch BacklogLogic.capacityForecast(
            pendingMinutes: pendingWorkloadMinutes,
            workingHours: optimizerService.workingHours,
            workingDays: optimizerService.workingDays
        ) {
        case .over, .afterHours: return true
        case .fits:              return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(
                title: "Backlog",
                showBack: true,
                // HIG: back label = the name of the previous screen. We
                // return to the main popover (today + timeline + inline backlog
                // card) — that's «Today», not «Backlog» (the fullscreen form
                // of which we currently are).
                backLabel: "Today",
                onBack: onExit
            )

            // Meta-band — header summary + smart-actions + filter chips.
            // Lives flat against the popover background (no rounded chrome
            // around it, unlike the inline Tasks card on the main view):
            // the fullscreen Backlog reads as ONE stream from header to
            // last row, not as «rules in a card with evidence below».
            // Birman: «one object — one form» — at popover scale the
            // whole list IS the object, so the separate rules-card chrome
            // would only fragment it.
            //
            // Hierarchy without chrome is carried by typography (the
            // metric-voice count vs row text), spacing, and a single
            // `SkinSeparator` at the rules→evidence seam.
            VStack(spacing: 0) {
                blockHeader
                // Smart-actions row appears only when the day is in a
                // hard capacity state (overflow / after-hours) — the one
                // case where a contextual fix verb («Schedule overflow»,
                // «Pack urgent first») earns its own band. Soft
                // suggestions don't get a second surface here: the
                // header's persistent «Plan N» pill is the planning
                // verb, and stacking a banner + chip row above the list
                // was the main source of the cluttered top.
                if capacityForecastIsHard {
                    BacklogSmartActionsRow(
                        activeTasks: activeTasks,
                        remainingWorkdayMinutes: remainingWorkdayMinutes,
                        pendingWorkloadMinutes: pendingWorkloadMinutes,
                        optimizerService: optimizerService,
                        onScheduleBacklog: onScheduleBacklog,
                        onFocusOnDeadlines: onFocusOnDeadlines,
                        onRunRequest: onRunRequest,
                        onOpenPalette: onOpenPalette
                    )
                }
                // Single status tab strip — Apple Reminders-style
                // «view as…» chips with badge counts. No project /
                // colour / urgent rows below; the prototype keeps the
                // backlog visually quiet with one filter line.
                BacklogSmartFilterRow(
                    activeTasksCount: activeTasks.count,
                    counts: smartFilterCounts,
                    smartFilter: $smartFilter
                )
            }
            .padding(.horizontal, DS.Spacing.contentMargin)
            .padding(.top, DS.Spacing.xs)

            // Tasks flow directly under the rules — same stream, same
            // typography rhythm. The `+ Add task…` field anchors at the
            // bottom so the empty state isn't a dead end.
            mainContent
                .padding(.horizontal, DS.Spacing.contentMargin)
            // Selection mode replaces the add-task field with the
            // bulk-action toolbar — capturing a new task mid-curation
            // breaks the user's rhythm, and the toolbar IS the
            // selection set's affordance, so it earns the bottom slot.
            // Browse mode keeps the canonical add-task field.
            if selectionMode {
                BacklogBulkActionsToolbar(
                    count: selectedTaskIds.count,
                    canSchedule: onScheduleBacklog != nil,
                    onSchedule: { bulkSchedule() },
                    onDeferOneDay: { bulkDefer(days: 1) },
                    onDeferOneWeek: { bulkDefer(days: 7) },
                    onFreeze: { bulkFreeze() },
                    onDelete: { bulkDelete() },
                    onDone: { exitSelection() }
                )
                    .padding(.horizontal, DS.Spacing.contentMargin)
                    .padding(.bottom, DS.Spacing.md)
            } else {
                BacklogAddTaskField(
                    newTaskTitle: $newTaskTitle,
                    parsedNewTaskTitle: $parsedNewTaskTitle,
                    isInputFocused: $isInputFocused,
                    activeTasksIsEmpty: activeTasks.isEmpty,
                    canCreateWithDetails: onCreateTaskWithDetails != nil,
                    onSubmit: { addTask() },
                    onShiftSubmit: { openCreateWithDetails() }
                )
                    .padding(.horizontal, DS.Spacing.contentMargin)
                    .padding(.bottom, DS.Spacing.md)
            }
        }
        .motionAwareAnimation(DS.Animation.standard, value: selectionMode, reduceMotion: reduceMotion)
        // PRINCIPLES §9 — verbs travel through the environment; one
        // installation point covers every row in the list.
        .environment(\.backlogRowActions, rowActions)
        .frame(width: DS.Popover.width, height: DS.Popover.height)
        .background(BacklogHotKeyBindings(
            isInputFocused: isInputFocused,
            visibleTasks: visibleTasks,
            maxHotKeyTasks: Self.maxHotKeyTasks,
            onComplete: { task in complete(task) }
        ))
        // Inline deadline picker — mirrors the inline `BacklogView` so the
        // «Set deadline…» context-menu item produces the same popover in
        // both backlog modes.
        .popover(item: $deadlinePickerTask, arrowEdge: .top) { task in
            DeadlinePickerPopover(
                initialDeadline: task.deadline,
                title: task.title,
                onSave: { newDeadline in
                    updateTaskDeadline(task: task, to: newDeadline)
                    deadlinePickerTask = nil
                },
                onCancel: { deadlinePickerTask = nil }
            )
        }
        .onChange(of: newTaskTitle) { _, newValue in
            parsedNewTaskTitle = BacklogTitleParser.parse(newValue)
        }
        .onChange(of: activeTasks.count) { _, _ in
            // Drop any IDs the user has selected for bulk action that
            // are no longer in the active set (completed externally,
            // synced away, deleted from another window). Without this
            // the toolbar would happily run `bulkDefer` on ghost IDs.
            if !selectedTaskIds.isEmpty {
                let liveIds = Set(activeTasks.map(\.id))
                selectedTaskIds.formIntersection(liveIds)
                if selectedTaskIds.isEmpty && selectionMode {
                    // Keep the user in selection mode even when their
                    // last selected row vanished — the toolbar still
                    // surfaces «Done» so they can leave deliberately.
                }
            }
            if let smart = smartFilter,
               (smartFilterCounts[smart] ?? 0) == 0 {
                smartFilter = nil
            }
        }
    }

    // MARK: - Block header
    //
    // We delegate to the shared `BacklogHeader` (see Components/BacklogHeader.swift)
    // in `.fullscreen` mode. The same component renders the inline card too —
    // all header tweaks now live in one file. What remains here is only
    // the GeometryReader-measurement of the bottom Y (for palette anchoring)
    // and the ETA chip, passed into the component via a closure.

    private var blockHeader: some View {
        BacklogHeader(
            mode: .fullscreen,
            totalCount: activeTasks.count,
            urgentCount: urgentCount,
            pendingMinutes: pendingWorkloadMinutes,
            remainingWorkdayMinutes: remainingWorkdayMinutes,
            optimizerService: optimizerService,
            capacityRingTooltip: capacityRingTooltip,
            useSmartSort: $useSmartSort,
            // «Plan N» pill — visible whenever the backlog still has
            // unscheduled work. Surfaces the bulk-scheduling verb as a
            // persistent header object (instead of hiding it behind the
            // SmartActions state machine). Counts only `.pending` tasks
            // so already-scheduled ones don't inflate the badge.
            onPlanBacklog: onScheduleBacklog,
            pendingUnscheduledCount: pendingUnscheduledCount
        )
        // Publish the block header's bottom Y so the command palette (a
        // sibling overlay anchored via `OptimizerBottomKey` in MenuBarView)
        // lands right under the header inside the fullscreen block — same
        // pattern QuickActions uses on the main view. Without this the
        // palette inherits the stale main-view Y when ⌘K is pressed in
        // fullscreen and ends up floating inside the task list.
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: OptimizerBottomKey.self,
                    value: geo.frame(in: .named(menuBarRootCoordinateSpace)).maxY
                )
            }
        )
    }

/// Project + colour-tag filter chips. Renders as a horizontal scroll
    /// row only when the active set has at least one project context or
    /// at least one colour-tagged task — empty data ⇒ no row, so the
    /// header stays calm on simple backlogs. Each chip toggles a
    /// session-local filter; the underlying `activeFiltered` recomposes
    /// on every render. Birman: «rules are objects on the screen».
    ///
    /// Project chips hide when the picker has already selected an active
    /// project: in that state the backlog is already filtered by one
    /// context, and the chip row would show either one redundant
    /// «Personal» pill, or other-project chips whose clicks would
    /// intersect with the picker and yield an empty result. Color chips
    /// remain — they work on top of the project and don't duplicate it.
// MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if visibleTasks.isEmpty && completedToday.isEmpty && backlogService.frozen.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Capacity sections — matches the inline `BacklogView` layout.
            // Hot-key indices (1–9 for the first nine VISIBLE rows) need to
            // span the partition: the first task in `fitting` gets index 1,
            // and indices keep counting through the marker into `overflowing`
            // so digit-press still completes the Nth row the user sees.
            let plan = BacklogLogic.CapacitySectionPlan(
                orderedTasks: visibleTasks,
                remainingWorkdayMinutes: remainingWorkdayMinutes
            )
            let fittingCount = plan.fitting.count

            // Same shadow-first / naive-fallback merge as the inline
            // BacklogView. Once the shadowProposal lands in either
            // place, both surfaces inherit the GA's actual per-task
            // slots without further wiring.
            let shadowSlots = BacklogLogic.proposedSlotsFromShadow(
                optimizerService.shadowProposal
            )
            let naiveSlots = BacklogLogic.naiveProposedSlots(
                overflowingTasks: plan.overflowing,
                workingHours: optimizerService.workingHours,
                workingDays: optimizerService.workingDays
            )
            let proposedSlots = naiveSlots.merging(shadowSlots) { _, shadow in shadow }

            ScrollView {
                VStack(spacing: DS.Spacing.xs) {
                    ForEach(Array(plan.fitting.enumerated()), id: \.element.id) { index, task in
                        row(
                            for: task,
                            hotKey: index < Self.maxHotKeyTasks ? index + 1 : nil,
                            proposedSlot: nil
                        )
                    }

                    // Mid-list `SpillOverMarker` removed — its role is now
                    // covered by the `smartActionsRow` rendered above the
                    // ScrollView (between header and list). Birman: one
                    // signal, one place. Each overflow row carries its own
                    // `→ HH:MM` ghost-slot in the trailing meta column.

                    ForEach(Array(plan.overflowing.enumerated()), id: \.element.id) { index, task in
                        let absoluteIndex = fittingCount + index
                        row(
                            for: task,
                            hotKey: absoluteIndex < Self.maxHotKeyTasks ? absoluteIndex + 1 : nil,
                            proposedSlot: proposedSlots[task.id]
                        )
                    }

                    BacklogTombstones(
                        completedToday: completedToday,
                        frozen: backlogService.frozen,
                        showCompleted: $showCompletedToday,
                        showFrozen: $showFrozen,
                        alignedLeadingGutter: true,
                        minRowHeight: BacklogTaskRow.compactRowHeight,
                        onUncomplete: { task in uncomplete(task) },
                        onUnfreezeOne: { task in unfreezeOneWithUndo(task) },
                        onUnfreezeAll: { unfreezeAllWithUndo() }
                    )
                }
                // Inside the card chrome — match BacklogView's inner padding
                // so the column of rows aligns visually with the inline
                // version on the main view.
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.sm)
            }
            .coordinateSpace(name: Self.scrollSpace)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)
        }
    }

    /// Coordinate-space name for the task list ScrollView. Local to the
    /// fullscreen view so it doesn't collide with sibling scrolls.
    static let scrollSpace = "BacklogFullscreenScroll"

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: DS.Spacing.md) {
            // PRINCIPLES §8: type sizes come from macOS text styles. The
            // hero checkmark uses `.largeTitle` rather than a hand-tuned
            // 36pt — Dynamic Type then scales it alongside the headline
            // and body strings below.
            Image(systemName: "checkmark.circle")
                .font(.largeTitle.weight(.light))
                .foregroundStyle(skin.resolvedTextTertiary)
            Text("Backlog is empty")
                .font(DS.Typography.headline(skin: skin))
                .foregroundStyle(skin.resolvedTextPrimary)
            Text("Add a task below to get going.")
                .font(DS.Typography.body(skin: skin))
                .foregroundStyle(skin.resolvedTextSecondary)
        }
        .multilineTextAlignment(.center)
        .padding(DS.Spacing.lg)
    }


    // MARK: - Task row

    /// One `BacklogRowActions` value for every row — verbs travel through
    /// the environment (PRINCIPLES §9), so the row builder below carries
    /// only facts. Optional verbs pass the host's optional handlers
    /// straight through: a nil handler hides the affordance in the row,
    /// exactly like the old nil-able callback parameters did.
    var rowActions: BacklogRowActions {
        BacklogRowActions(
            complete: { complete($0) },
            edit: { onEditTask($0) },
            delete: { delete($0) },
            freeze: { freeze($0) },
            reorderDrop: { dropped, target in
                handleReorderDrop(dropped: dropped, targetId: target.id)
            },
            moveUp: { moveTask($0, by: -1) },
            moveDown: { moveTask($0, by: +1) },
            moveToTop: { moveTaskToEdge($0, toTop: true) },
            moveToBottom: { moveTaskToEdge($0, toTop: false) },
            focusPrevious: { focusRow(offsetFrom: $0.id, by: -1) },
            focusNext: { focusRow(offsetFrom: $0.id, by: +1) },
            findSlot: onScheduleTask,
            setPreferredPeriod: { task, period in setPreferredPeriod(period, on: task) },
            splitTask: onSplitTask,
            snooze: { task, days in snoozeTaskDeadline(task, byDays: days) },
            reschedule: onRescheduleTask,
            setDeadline: { deadlinePickerTask = $0 },
            toggleUrgent: { toggleUrgent($0) },
            loadAlternatives: onLoadAlternativesForTask,
            pickAlternative: onPickAlternativeScenario,
            toggleSelection: { toggleSelection($0) }
        )
    }

    /// Builds one task row — facts only; verbs come from `rowActions`
    /// installed on the screen's environment. Full reorder/drag
    /// affordances: hover chevrons, drag-to-reorder, context menu.
    @ViewBuilder
    private func row(for task: BacklogTask, hotKey: Int?, proposedSlot: Date? = nil) -> some View {
        BacklogTaskRow(
            task: task,
            isUrgent: BacklogLogic.isUrgent(task),
            canMoveUp: canMoveUp(task),
            canMoveDown: canMoveDown(task),
            isFocused: focusedTaskId == task.id,
            proposedSlot: proposedSlot,
            sprintHotKey: hotKey,
            defaultTaskDurationMinutes: optimizerService.defaultTaskDurationMinutes,
            selectionMode: selectionMode,
            isSelected: selectedTaskIds.contains(task.id)
        )
        .focusable()
        .focused($focusedTaskId, equals: task.id)
        .focusEffectDisabled()
    }

    /// Persist a per-task preferred-period preference. Pulled out of
    /// `row(for:hotKey:proposedSlot:)` so the row builder is pure
    /// argument-marshaling and the date-touching write lives next to
    /// the other task mutators.
    private func setPreferredPeriod(_ period: Period?, on task: BacklogTask) {
        var updated = task
        updated.preferredPeriod = period
        backlogService.updateTask(updated)
    }

    /// Push a task's deadline forward by `days`. Tasks without an
    /// existing deadline get one anchored at start-of-today + N days
    /// so the «snooze» verb has a concrete meaning even on never-dated
    /// rows. Mirrors the bulk-defer path's per-task body — both branches
    /// share the same anchor + add-days logic.
    private func snoozeTaskDeadline(_ task: BacklogTask, byDays days: Int) {
        var updated = task
        let cal = Calendar.current
        let base = task.deadline ?? cal.startOfDay(for: Date())
        if let pushed = cal.date(byAdding: .day, value: days, to: base) {
            updated.deadline = pushed
            backlogService.updateTask(updated)
        }
    }

    // MARK: - Multi-select

    /// Toggle a task's membership in the bulk-action set. Entering the
    /// first selection also flips `selectionMode` on so every row's
    /// checkbox switches to the square-glyph «set membership» mode at
    /// once — consistency: the user shouldn't have to flip a separate
    /// toggle before their first pick lands.
    private func toggleSelection(_ task: BacklogTask) {
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

    /// Exit multi-select. Clears the set and flips the mode off; the
    /// add-task field returns to the bottom slot. Bound to Esc and the
    /// toolbar's «Done» button.
    func exitSelection() {
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            selectedTaskIds.removeAll()
            selectionMode = false
        }
    }

    /// Currently selected tasks, resolved against the live store at
    /// call time so a deletion / completion mid-flow doesn't leave
    /// dangling IDs in the bulk-action payload. Returned in the same
    /// order the rows are rendered so undo descriptions read in
    /// reading order.
    var selectedTasks: [BacklogTask] {
        let ids = selectedTaskIds
        guard !ids.isEmpty else { return [] }
        return visibleTasks.filter { ids.contains($0.id) }
    }

}
