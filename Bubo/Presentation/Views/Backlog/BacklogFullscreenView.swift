import SwiftUI
import BuboDomain
import BuboOptimizer

// MARK: - Backlog Fullscreen View
//
// Composition only (UI_REFACTORING.md, stage 2): session state, derived
// computation, and data mutations live on `BacklogScreenModel`; row verbs
// travel through `\.backlogRowActions` (stage 1). What stays here is
// what genuinely belongs to the view layer — FocusState, the navigation
// closures from the host, and the assembly of subviews.
//
// Visually the screen reads as one stream from the popover header down
// to the last row: header summary (with the «Plan N» pill — this
// screen's single planner verb), the filter strip, the task list, and
// the add-task field at the bottom (REDESIGN.md R4 — management only).
struct BacklogFullscreenView: View {

    // MARK: Host wiring — navigation + optimizer pipes

    var onExit: () -> Void
    var onEditTask: (BacklogTask) -> Void
    /// Open the compact creation form pre-filled with the draft (⇧↩ / "›").
    var onCreateTaskWithDetails: ((_ prefillTitle: String, _ prefillDuration: Int?) -> Void)? = nil
    /// Schedule the unscheduled backlog via the optimizer (header «Plan N»
    /// — this screen's single planner verb, REDESIGN.md R4).
    var onScheduleBacklog: (() async -> Void)? = nil
    /// Per-task «Find a slot now».
    var onScheduleTask: ((BacklogTask) -> Void)? = nil
    /// ⌥-click alternatives preview for one task.
    var onLoadAlternativesForTask: ((BacklogTask) async -> [ScheduleScenario])? = nil
    /// Commit a previewed alternative scenario.
    var onPickAlternativeScenario: ((ScheduleScenario) -> Void)? = nil
    /// Per-task split into shorter blocks.
    var onSplitTask: ((BacklogTask) -> Void)? = nil
    /// Open the palette seeded with one task («Reschedule…»).
    var onRescheduleTask: ((BacklogTask) -> Void)? = nil

    // MARK: Model + view-layer state

    @State private var model: BacklogScreenModel
    /// Services the subviews still take directly (header ring, smart
    /// actions row, default duration for rows).
    private let optimizerService: OptimizerService

    @Environment(\.activeSkin) var skin
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @FocusState var isInputFocused: Bool
    /// Row-level keyboard focus; nil when the input field owns focus.
    @FocusState var focusedTaskId: String?

    /// Hot-keys bind to the first N visible rows (digits 1…9).
    static let maxHotKeyTasks = 9
    /// Coordinate-space name for the task list ScrollView.
    static let scrollSpace = "BacklogFullscreenScroll"

    init(
        backlogService: BacklogService,
        optimizerService: OptimizerService,
        settings: ReminderSettings,
        onExit: @escaping () -> Void,
        onEditTask: @escaping (BacklogTask) -> Void,
        onCreateTaskWithDetails: ((_ prefillTitle: String, _ prefillDuration: Int?) -> Void)? = nil,
        onUndoableAction: ((_ message: String, _ undo: @escaping () -> Void) -> Void)? = nil,
        onScheduleBacklog: (() async -> Void)? = nil,
        onScheduleTask: ((BacklogTask) -> Void)? = nil,
        onLoadAlternativesForTask: ((BacklogTask) async -> [ScheduleScenario])? = nil,
        onPickAlternativeScenario: ((ScheduleScenario) -> Void)? = nil,
        onSplitTask: ((BacklogTask) -> Void)? = nil,
        onRescheduleTask: ((BacklogTask) -> Void)? = nil
    ) {
        self.optimizerService = optimizerService
        self.onExit = onExit
        self.onEditTask = onEditTask
        self.onCreateTaskWithDetails = onCreateTaskWithDetails
        self.onScheduleBacklog = onScheduleBacklog
        self.onScheduleTask = onScheduleTask
        self.onLoadAlternativesForTask = onLoadAlternativesForTask
        self.onPickAlternativeScenario = onPickAlternativeScenario
        self.onSplitTask = onSplitTask
        self.onRescheduleTask = onRescheduleTask

        let model = BacklogScreenModel(
            backlogService: backlogService,
            optimizerService: optimizerService,
            settings: settings
        )
        model.onUndoable = onUndoableAction
        _model = State(initialValue: model)
    }

    // MARK: Body

    var body: some View {
        // Stage-4 scaffold: slot order fixed by the type. Slots carry only
        // horizontal margins and genuine frame insets (the footer's bottom
        // margin) — no outer vertical nudges; inter-band rhythm is the
        // bands' own chrome under a spacing-0 scaffold (PRINCIPLES §2).
        PopoverScreenLayout {
            PopoverHeader(
                title: "Backlog",
                showBack: true,
                // HIG: back label = the name of the previous screen.
                backLabel: "Today",
                onBack: onExit
            )

            // PRINCIPLES §2 — no outer vertical nudge; the gap below the
            // popover title comes from BacklogHeader's own chrome.
            blockHeader
                .padding(.horizontal, DS.Spacing.contentMargin)
        } actionRail: {
            // REDESIGN.md R4 — this screen's job is managing the list.
            // The hard-state SmartActions row duplicated the header's
            // «Plan N» pill (§1: one verb per surface); the capacity
            // verdict under the count already carries the diagnosis.
            EmptyView()
        } status: {
            EmptyView()
        } strips: {
            BacklogSmartFilterRow(
                activeTasksCount: model.activeTasks.count,
                counts: model.smartFilterCounts,
                smartFilter: $model.smartFilter
            )
            .padding(.horizontal, DS.Spacing.contentMargin)
        } content: {
            mainContent
                .padding(.horizontal, DS.Spacing.contentMargin)
        } footer: {
            if model.selectionMode {
                // The bulk bar is footer CHROME (PRINCIPLES §11/§12):
                // its tinted band and top hairline bleed edge-to-edge
                // and sit flush at the bottom — inset by the old
                // horizontal + bottom padding it floated as a strip
                // with the screen background leaking around it. The
                // bar's own content padding carries the 16 pt axis.
                BacklogBulkActionsToolbar(
                    count: model.selectedTaskIds.count,
                    canSchedule: onScheduleBacklog != nil,
                    onSchedule: { bulkSchedule() },
                    onDeferOneDay: { model.bulkDefer(days: 1) },
                    onDeferOneWeek: { model.bulkDefer(days: 7) },
                    onFreeze: { model.bulkFreeze() },
                    onDelete: { model.bulkDelete() },
                    onDone: { model.exitSelection() }
                )
            } else {
                BacklogAddTaskField(
                    newTaskTitle: $model.newTaskTitle,
                    parsedNewTaskTitle: $model.parsedNewTaskTitle,
                    isInputFocused: $isInputFocused,
                    activeTasksIsEmpty: model.activeTasks.isEmpty,
                    canCreateWithDetails: onCreateTaskWithDetails != nil,
                    onSubmit: { model.addTask() },
                    onShiftSubmit: { openCreateWithDetails() }
                )
                .padding(.horizontal, DS.Spacing.contentMargin)
                .padding(.bottom, DS.Spacing.md)
            }
        }
        .motionAwareAnimation(DS.Animation.standard, value: model.selectionMode, reduceMotion: reduceMotion)
        // PRINCIPLES §9 — verbs travel through the environment; one
        // installation point covers every row in the list.
        .environment(\.backlogRowActions, rowActions)
        .frame(width: DS.Popover.width, height: DS.Popover.height)
        .background(BacklogHotKeyBindings(
            isInputFocused: isInputFocused,
            visibleTasks: model.visibleTasks,
            maxHotKeyTasks: Self.maxHotKeyTasks,
            onComplete: { task in model.complete(task) }
        ))
        .popover(item: $model.deadlinePickerTask, arrowEdge: .top) { task in
            DeadlinePickerPopover(
                initialDeadline: task.deadline,
                title: task.title,
                onSave: { newDeadline in
                    model.updateTaskDeadline(task: task, to: newDeadline)
                    model.deadlinePickerTask = nil
                },
                onCancel: { model.deadlinePickerTask = nil }
            )
        }
        .onAppear { model.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, newValue in
            model.reduceMotion = newValue
        }
        .onChange(of: model.newTaskTitle) { _, newValue in
            model.parsedNewTaskTitle = BacklogTitleParser.parse(newValue)
        }
        .onChange(of: model.activeTasks.count) { _, _ in
            model.pruneStaleSelection()
        }
    }

    // MARK: - Block header

    private var blockHeader: some View {
        BacklogHeader(
            mode: .fullscreen,
            totalCount: model.activeTasks.count,
            urgentCount: model.urgentCount,
            pendingMinutes: model.pendingWorkloadMinutes,
            remainingWorkdayMinutes: model.remainingWorkdayMinutes,
            optimizerService: optimizerService,
            capacityRingTooltip: model.capacityRingTooltip,
            useSmartSort: $model.useSmartSort,
            onPlanBacklog: onScheduleBacklog,
            pendingUnscheduledCount: model.pendingUnscheduledCount
        )
        // Publish the header's bottom Y so the ⌘K palette overlay lands
        // right under it inside the fullscreen block.
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: OptimizerBottomKey.self,
                    value: geo.frame(in: .named(menuBarRootCoordinateSpace)).maxY
                )
            }
        )
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if model.visibleTasks.isEmpty && model.completedToday.isEmpty && model.frozen.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Hot-key indices (1–9 for the first nine VISIBLE rows) span
            // the fits → overflow partition so digit-press still completes
            // the Nth row the user sees.
            let plan = model.sectionPlan
            let fittingCount = plan.fitting.count
            let proposedSlots = model.proposedSlots

            ScrollView {
                VStack(spacing: DS.Spacing.xs) {
                    ForEach(Array(plan.fitting.enumerated()), id: \.element.id) { index, task in
                        row(
                            for: task,
                            hotKey: index < Self.maxHotKeyTasks ? index + 1 : nil,
                            proposedSlot: nil
                        )
                    }

                    ForEach(Array(plan.overflowing.enumerated()), id: \.element.id) { index, task in
                        let absoluteIndex = fittingCount + index
                        row(
                            for: task,
                            hotKey: absoluteIndex < Self.maxHotKeyTasks ? absoluteIndex + 1 : nil,
                            proposedSlot: proposedSlots[task.id]
                        )
                    }

                    BacklogTombstones(
                        completedToday: model.completedToday,
                        frozen: model.frozen,
                        showCompleted: $model.showCompletedToday,
                        showFrozen: $model.showFrozen,
                        alignedLeadingGutter: true,
                        minRowHeight: BacklogTaskRow.compactRowHeight,
                        onUncomplete: { task in model.uncomplete(task) },
                        onUnfreezeOne: { task in model.unfreezeOneWithUndo(task) },
                        onUnfreezeAll: { model.unfreezeAllWithUndo() }
                    )
                }
                // Rows hang on the host's contentMargin axis — the same
                // grid as the timeline's event rows. The extra sm inset
                // here made the list its own third left edge.
                .padding(.vertical, DS.Spacing.sm)
            }
            .coordinateSpace(name: Self.scrollSpace)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: DS.Spacing.md) {
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

    // MARK: - Rows

    /// One `BacklogRowActions` value for every row — model verbs plus the
    /// host's optional optimizer pipes plus the view-owned focus moves.
    /// A nil host handler hides the affordance in the row.
    var rowActions: BacklogRowActions {
        BacklogRowActions(
            complete: { model.complete($0) },
            edit: { onEditTask($0) },
            delete: { model.delete($0) },
            freeze: { model.freeze($0) },
            reorderDrop: { dropped, target in
                model.handleReorderDrop(dropped: dropped, target: target)
            },
            moveUp: { model.moveTask($0, by: -1) },
            moveDown: { model.moveTask($0, by: +1) },
            moveToTop: { model.moveTaskToEdge($0, toTop: true) },
            moveToBottom: { model.moveTaskToEdge($0, toTop: false) },
            focusPrevious: { focusRow(offsetFrom: $0.id, by: -1) },
            focusNext: { focusRow(offsetFrom: $0.id, by: +1) },
            findSlot: onScheduleTask,
            setPreferredPeriod: { task, period in model.setPreferredPeriod(period, on: task) },
            splitTask: onSplitTask,
            snooze: { task, days in model.snoozeDeadline(task, byDays: days) },
            reschedule: onRescheduleTask,
            setDeadline: { model.deadlinePickerTask = $0 },
            toggleUrgent: { model.toggleUrgent($0) },
            loadAlternatives: onLoadAlternativesForTask,
            pickAlternative: onPickAlternativeScenario,
            toggleSelection: { model.toggleSelection($0) }
        )
    }

    /// Builds one task row — facts only; verbs come from `rowActions`.
    @ViewBuilder
    private func row(for task: BacklogTask, hotKey: Int?, proposedSlot: Date? = nil) -> some View {
        BacklogTaskRow(
            task: task,
            isUrgent: BacklogLogic.isUrgent(task),
            canMoveUp: model.canMoveUp(task),
            canMoveDown: model.canMoveDown(task),
            isFocused: focusedTaskId == task.id,
            proposedSlot: proposedSlot,
            sprintHotKey: hotKey,
            defaultTaskDurationMinutes: optimizerService.defaultTaskDurationMinutes,
            selectionMode: model.selectionMode,
            isSelected: model.selectedTaskIds.contains(task.id)
        )
        .focusable()
        .focused($focusedTaskId, equals: task.id)
        .focusEffectDisabled()
    }

    // MARK: - View-layer helpers

    /// Move keyboard focus between visible rows. Boundaries clamp silently.
    /// Stays on the view: FocusState can't live on the model.
    private func focusRow(offsetFrom currentId: String, by delta: Int) {
        let tasks = model.visibleTasks
        guard let idx = tasks.firstIndex(where: { $0.id == currentId }) else { return }
        let target = idx + delta
        guard target >= 0, target < tasks.count else { return }
        focusedTaskId = tasks[target].id
    }

    /// Open the compact creation form with the current draft (⇧↩ / "›").
    private func openCreateWithDetails() {
        let parsed = model.parsedNewTaskTitle
        guard let onCreateTaskWithDetails else {
            model.addTask()
            return
        }
        let title = parsed.cleaned
        let duration = parsed.durationMinutes
            ?? BacklogTitleParser.guessDuration(for: title)
        onCreateTaskWithDetails(title, duration)
        model.clearDraft()
        isInputFocused = false
    }

    /// Schedule every selected pending task in one optimizer run — reuses
    /// the host's `onScheduleBacklog` pipe, then exits selection so the
    /// toast surfaces over the regular list.
    private func bulkSchedule() {
        Haptics.tap()
        let run = onScheduleBacklog
        model.exitSelection()
        guard let run else { return }
        Task { await run() }
    }
}
