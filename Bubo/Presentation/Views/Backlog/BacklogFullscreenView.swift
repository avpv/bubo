import SwiftUI

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
    /// See `BacklogView.onSwitchScenario`.
    var onSwitchScenario: ((Int) -> Void)? = nil
    /// See `BacklogView.onLockTodaysEvents`.
    var onLockTodaysEvents: (() -> Void)? = nil
    /// Open the command palette seeded with a single task (per-task scope
    /// optimizer entry — context menu's «Reschedule…» on a row).
    var onRescheduleTask: ((BacklogTask) -> Void)? = nil

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ReminderSettings.self) private var settings

    /// Hot-keys are bound to the first N visible rows. 9 covers the digit
    /// keyboard 1…9; tasks beyond that need scrolling and a click. Same
    /// «keyboard-first completion» idea as Things and Linear.
    static let maxHotKeyTasks = 9

    @State private var newTaskTitle = ""
    /// Cached parse result for `newTaskTitle`. Updated from `onChange` so
    /// the title/duration pair is computed once per keystroke.
    @State private var parsedNewTaskTitle: (cleaned: String, durationMinutes: Int?) = ("", nil)
    @FocusState private var isInputFocused: Bool
    /// Row-level keyboard focus, mirroring BacklogView. `nil` when the input
    /// field owns focus instead. Driven by ↑/↓ between rows; ⌘↑/↓ reorders.
    @FocusState private var focusedTaskId: String?

    @State private var showCompletedToday: Bool = false
    @State private var showFrozen: Bool = false
    /// Urgent-only filter — narrows the list to tasks whose deadline falls
    /// inside the urgency window. Session-local. Mirrors BacklogView's
    /// `urgentOnlyFilter` so users carry the same mental model across views.
    @State private var urgentOnlyFilter: Bool = false
    /// Project / context filter chip. nil = «All projects». When set,
    /// only tasks whose `context` matches are kept by `activeFiltered`.
    /// Reifies the optimizer's `fromProject(name:)` intent at the UI
    /// level — Birman: «rules are objects on the screen». Session-local;
    /// resets on every fullscreen open so the user doesn't get stuck in
    /// a forgotten filter.
    @State private var projectFilter: String? = nil
    /// Same shape as `projectFilter` but for the task's optional
    /// `colorTag`. Reifies what would otherwise be a colour-coded tag
    /// search via `fromCalendar`/colour metadata.
    @State private var colorFilter: EventColorTag? = nil

    /// One-of-N "view as…" filter at the top of the fullscreen backlog,
    /// borrowed from Apple Reminders' Today / Scheduled / Flagged cards.
    /// nil = "All". Composes with the existing chips below — selecting
    /// "Today" + a project narrows to deadline-today tasks in that
    /// project, which is the natural reading.
    @State private var smartFilter: BacklogLogic.SmartFilter? = nil
    /// Smart-sort toggle — re-orders the list by `BacklogLogic.smartScore`
    /// instead of user drag order. Session-local.
    @State private var useSmartSort: Bool = false
    /// Collapse the secondary filter rows (smart-filter chips,
    /// project/colour chips) inside the header card. Header summary and
    /// `SmartActions` (diagnosis + action) stay visible regardless — those
    /// are content the user must always see. The chevron in the header is
    /// the manual override; sticky-on-scroll auto-engages it as the user
    /// pulls down into the list and disengages back at the top of the list.
    @State private var filtersCollapsed: Bool = false

    /// Task whose deadline is currently being edited via the row's
    /// «Set deadline…» context-menu item. Mirrors `BacklogView` so both
    /// modes host the same inline picker.
    @State private var deadlinePickerTask: BacklogTask? = nil

    /// IDs of tasks currently in the multi-select set. When non-empty,
    /// the bulk-action toolbar at the bottom replaces the add-task
    /// field, and each row's leading checkbox toggles set membership
    /// instead of completing the task. Empty + `selectionMode == false`
    /// is the default «browse» state. Birman: the rule is an object
    /// on the screen — the set IS the toolbar, not a hidden mode.
    @State private var selectedTaskIds: Set<String> = []

    /// True while the user is curating a bulk-action set. Decoupled
    /// from `selectedTaskIds.isEmpty` so the user can deselect the
    /// last row without instantly snapping out of the mode (the
    /// toolbar stays visible with a «select more, or hit Done»
    /// affordance). Cleared on Esc / «Done» / page exit.
    @State private var selectionMode: Bool = false

    /// All active tasks (without urgent filters etc.) — the common basis for
    /// computing the capacity ring (which shows the total queue load, not
    /// a filtered subset).
    private var activeTasks: [BacklogTask] {
        BacklogLogic.activeTasks(backlogService.tasks)
    }

    /// Active set after all display filters. Composes (in order):
    /// active-project picker → urgent toggle → project chip → color chip.
    /// Capacity (`pendingWorkloadMinutes`) keeps reading the unfiltered
    /// `activeTasks`, so «focus on the project» narrows what is shown,
    /// but not the size of the day.
    private var activeFiltered: [BacklogTask] {
        var result = activeTasks
        if let project = activeProjectName {
            result = result.filter { ($0.context ?? "") == project }
        }
        if urgentOnlyFilter {
            result = result.filter { BacklogLogic.isUrgent($0) }
        }
        if let smart = smartFilter {
            result = result.filter {
                BacklogLogic.matchesSmartFilter($0, filter: smart)
            }
        }
        if let project = projectFilter {
            result = result.filter { $0.context == project }
        }
        if let color = colorFilter {
            result = result.filter { $0.colorTag == color }
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
    private var activeProjectName: String? {
        settings.activeProjectTitle(remindersService: AppleRemindersService.shared)
    }

    /// Distinct, sorted list of project / context labels in the active
    /// task set. Drives the project filter chip's picker. Empty when no
    /// task carries a context — in that case the chip is suppressed.
    private var availableProjects: [String] {
        let raw = activeTasks.compactMap { $0.context?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(raw)).sorted()
    }

    /// Distinct color tags present in the active task set.
    private var availableColorTags: [EventColorTag] {
        let raw = activeTasks.compactMap { $0.colorTag }
        return Array(Set(raw)).sorted { $0.rawValue < $1.rawValue }
    }

    /// Tasks rendered in the list. User order (or smart-sort,
    /// if the toggle is on), plus the urgent-only filter. Parallel to the
    /// inline BacklogView — the same mental set of tasks, just at full
    /// popover size.
    private var visibleTasks: [BacklogTask] {
        useSmartSort ? BacklogLogic.smartSorted(activeFiltered) : activeFiltered
    }

    /// Total scheduled minutes across the visible set — drives the ETA chip
    /// («when the backlog will be done if started now»).
    private var totalMinutes: Int {
        visibleTasks.reduce(0) { $0 + $1.durationMinutes }
    }

    /// Projected end-of-session time: `now` + total visible minutes. Answers
    /// «when will I finish if I start right now?» — turns the total
    /// duration from a number into a time of day. If the ETA goes past
    /// midnight, a `+Nd` badge is added so the user can see that
    /// «all-today» is an illusion. Nil when there are no visible tasks.
    ///
    /// `now` is taken as a parameter (rather than read via `Date()`) so
    /// that `TimelineView` can recompute the ETA every minute without
    /// digging up computed properties. Otherwise the number sticks at
    /// the moment the popover opens — the user sits for an hour, the
    /// ETA shows the time from when they opened it.
    private func etaLabel(now: Date) -> String? {
        guard !visibleTasks.isEmpty else { return nil }
        let eta = now.addingTimeInterval(TimeInterval(totalMinutes * 60))
        let timeStr = eta.formatted(date: .omitted, time: .shortened)

        let cal = Calendar.current
        if cal.isDate(eta, inSameDayAs: now) {
            return timeStr
        }
        let dayDelta = cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: now),
            to: cal.startOfDay(for: eta)
        ).day ?? 0
        if dayDelta >= 1 {
            return "\(timeStr) +\(dayDelta)d"
        }
        return timeStr
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
                // Ready-to-plan banner — surfaces a soft suggestion
                // («1 task ready to plan · Group snippets / Bubo found
                // a 1 h slot before standup. Schedule for 09:30?») as
                // a 2-line card with a trailing `Plan` link, matching
                // `ui_kits/backlog/index.html` `.tip-row`. The same
                // suggestion is suppressed inside `smartActionsRow`
                // when this banner is visible so the user reads it
                // once, not twice. PRINCIPLES.md §1: one primary
                // action per surface — `Plan` is it when the banner
                // shows.
                if let suggestion = activeBacklogSuggestion {
                    suggestionBanner(suggestion)
                }
                // Smart-actions row stays ALWAYS visible — it's
                // diagnosis + action attached to a real problem
                // («Pack urgent tasks first», «Schedule overflow»).
                // Hiding it would leave the user staring at the problem
                // with no remedy, which is worse than the chrome cost.
                BacklogSmartActionsRow(
                    activeTasks: activeTasks,
                    remainingWorkdayMinutes: remainingWorkdayMinutes,
                    pendingWorkloadMinutes: pendingWorkloadMinutes,
                    optimizerService: optimizerService,
                    activeBacklogSuggestion: activeBacklogSuggestion,
                    onScheduleBacklog: onScheduleBacklog,
                    onFocusOnDeadlines: onFocusOnDeadlines,
                    onRunRequest: onRunRequest,
                    onOpenPalette: onOpenPalette,
                    onSwitchScenario: onSwitchScenario,
                    onLockTodaysEvents: onLockTodaysEvents
                )
                // When the filter rows are collapsed but a filter is
                // active, surface a compact dismissable summary so the
                // user always knows why the list is narrowed. Replaces
                // the otherwise-invisible filter state with a tap-to-clear
                // pill (Birman: rules are objects on the screen).
                if filtersCollapsed && hasActiveFilters {
                    BacklogActiveFilterSummaryRow(
                        urgentOnlyFilter: $urgentOnlyFilter,
                        smartFilter: $smartFilter,
                        projectFilter: $projectFilter,
                        colorFilter: $colorFilter,
                        onClearAll: { clearAllActiveFilters() }
                    )
                }
                if !filtersCollapsed {
                    // Smart-filter row: Apple Reminders-style "view as…"
                    // chips with badge counts. One-of-N status/deadline
                    // restriction layered ABOVE project / colour chips so
                    // the user can stack "Today" with "in #design" without
                    // either chip group claiming the whole filter slot.
                    BacklogSmartFilterRow(
                        activeTasksCount: activeTasks.count,
                        counts: smartFilterCounts,
                        smartFilter: $smartFilter
                    )
                    // Filter chips: project + colour tag. Reify the
                    // optimizer's `fromProject` / colour-cohesion intents
                    // as visible UI objects rather than command-palette
                    // queries. Chips only render when the underlying data
                    // exists (no projects → no project chip).
                    BacklogFilterChipsRow(
                        projects: settings.activeProject == .all ? availableProjects : [],
                        colors: availableColorTags,
                        projectFilter: $projectFilter,
                        colorFilter: $colorFilter
                    )
                }
            }
            .padding(.horizontal, DS.Spacing.contentMargin)
            .padding(.top, DS.Spacing.xs)
            .motionAwareAnimation(DS.Animation.standard, value: filtersCollapsed, reduceMotion: reduceMotion)

            // Single skin-aware hairline at the only true semantic seam:
            // rules (header + smart-actions + filters) end here, evidence
            // (the task list) begins. PRINCIPLES.md §2: density is
            // respect for attention — one boundary, not three.
            // PRINCIPLES.md §10: line style delegated to the skin
            // (`SkinSeparator`), never a hard `Divider()`. Hidden when the
            // backlog is empty so a floating line never sits above the
            // empty state.
            if !activeTasks.isEmpty {
                SkinSeparator()
                    .padding(.horizontal, DS.Spacing.contentMargin)
                    .padding(.top, DS.Spacing.xs)
            }

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
            // Auto-disengage urgent filter if the urgent set dries up — same
            // safety net as in BacklogView, prevents stranding the user in
            // an empty filtered view. Project / colour filters get the
            // same treatment in the second onChange below.
            if urgentOnlyFilter, activeFiltered.isEmpty {
                urgentOnlyFilter = false
            }
            if let project = projectFilter, !availableProjects.contains(project) {
                projectFilter = nil
            }
            if let color = colorFilter, !availableColorTags.contains(color) {
                colorFilter = nil
            }
            if let smart = smartFilter,
               (smartFilterCounts[smart] ?? 0) == 0 {
                smartFilter = nil
            }
        }
        .onChange(of: urgentCount) { _, newValue in
            // Same safety net for the case where active count is unchanged
            // but the last urgent task lost its urgency (deadline edited
            // farther out) — onChange of `activeTasks.count` wouldn't fire.
            if urgentOnlyFilter, newValue == 0 {
                urgentOnlyFilter = false
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
            urgentOnlyFilter: $urgentOnlyFilter,
            filtersCollapsed: $filtersCollapsed,
            // «Plan N» pill — visible whenever the backlog still has
            // unscheduled work. Surfaces the bulk-scheduling verb as a
            // persistent header object (instead of hiding it behind the
            // SmartActions state machine). Counts only `.pending` tasks
            // so already-scheduled ones don't inflate the badge.
            onPlanBacklog: onScheduleBacklog,
            pendingUnscheduledCount: pendingUnscheduledCount,
            etaChip: { BacklogETAChip(etaLabel: etaLabel(now:)) }
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

// MARK: - Ready-to-plan banner

    /// The suggestion surfaced as a 2-line banner above the chip row,
    /// or `nil` when there's nothing soft to suggest *and* a hard
    /// state already owns the primary verb. Hard forecasts
    /// (`.over` / `.afterHours`) suppress the banner because
    /// `Schedule overflow` is the verb the user needs first — adding
    /// a softer «Plan…» card on top would compete for the same
    /// attention budget.
    private var activeBacklogSuggestion: SuggestionEngine.Suggestion? {
        let forecast = BacklogLogic.capacityForecast(
            pendingMinutes: pendingWorkloadMinutes,
            workingHours: optimizerService.workingHours,
            workingDays: optimizerService.workingDays
        )
        switch forecast {
        case .over, .afterHours:
            return nil
        case .fits:
            return optimizerService.suggestionEngine?.suggestion
        }
    }

    /// Two-line «ready to plan» banner driven by a soft suggestion.
    /// Sparkle icon · accent verb («N task ready to plan · <name>») ·
    /// machine-hint reason underneath · trailing `Plan` link, all
    /// behind the row hit-area so the user can tap anywhere to run.
    /// Mirrors `ui_kits/backlog/index.html` `.tip-row` layout.
    private func suggestionBanner(_ suggestion: SuggestionEngine.Suggestion) -> some View {
        var row = ContextualActionRow(
            icon: "sparkles",
            verb: bannerVerb(for: suggestion),
            subtext: suggestion.reason,
            kind: .run,
            action: { await onRunRequest?(suggestion.request, suggestion.reason) }
        )
        row.runLabel = "Plan"
        return row
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.top, DS.Spacing.xs)
            .padding(.bottom, DS.Spacing.xxs)
    }

    /// Compose the bold accent verb. If the underlying request has a
    /// name («Group snippets»), prepend a count summary so the row
    /// reads «1 task ready to plan · Group snippets». Falls back to
    /// the generic verb when the suggestion is unnamed.
    private func bannerVerb(for suggestion: SuggestionEngine.Suggestion) -> String {
        let n = activeTasks.count
        let countCopy: String
        switch n {
        case 0:  countCopy = "Ready to plan"
        case 1:  countCopy = "1\u{00A0}task ready to plan"
        default: countCopy = "\(n)\u{00A0}tasks ready to plan"
        }
        if let name = suggestion.request.name, !name.isEmpty {
            return "\(countCopy) \u{00B7} \(name)"
        }
        return countCopy
    }

    // MARK: - Active filter summary

    /// True when at least one filter is engaged. Drives whether the
    /// summary row appears under the collapsed header so the user can
    /// see the rules even when the chrome is hidden.
    private var hasActiveFilters: Bool {
        smartFilter != nil
            || projectFilter != nil
            || colorFilter != nil
            || urgentOnlyFilter
    }

/// Reset every chip-driven filter at once. Mirrors the per-chip
    /// clear paths but as one action so the «Clear» button stays a
    /// single tap. Project picker (`settings.activeProject`) is
    /// intentionally untouched — that's a navigation context, not a
    /// session-local filter.
    private func clearAllActiveFilters() {
        urgentOnlyFilter = false
        smartFilter = nil
        projectFilter = nil
        colorFilter = nil
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
                // Sticky-collapse probe — publishes the scroll offset of
                // the list into `BacklogScrollOffsetKey`. Lives at the top
                // of the content so its `minY` in the named coordinate
                // space reads zero at rest and goes negative as the user
                // scrolls down. `.frame(height: 0)` keeps it invisible.
                GeometryReader { geo in
                    Color.clear.preference(
                        key: BacklogScrollOffsetKey.self,
                        value: geo.frame(in: .named(Self.scrollSpace)).minY
                    )
                }
                .frame(height: 0)

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
            .onPreferenceChange(BacklogScrollOffsetKey.self) { offset in
                handleScrollOffset(offset)
            }
        }
    }

    /// Coordinate-space name for the task list ScrollView. Local to the
    /// fullscreen view so it doesn't collide with sibling scrolls.
    static let scrollSpace = "BacklogFullscreenScroll"

    /// Sticky-on-scroll state machine for the meta-band. Two thresholds
    /// instead of one create a hysteresis band — the user has to commit
    /// to a direction to flip the state, otherwise the chevron would
    /// flicker on small scroll wobbles.
    ///
    ///   offset > -8     → at the top, expand the chips
    ///   offset < -56    → committed scroll, collapse the chips
    ///
    /// The manual chevron in the header sets `filtersCollapsed` directly;
    /// next scroll movement may overrule it, which is the intended «scroll
    /// wins» behaviour (analogous to iOS large-title collapse).
    private func handleScrollOffset(_ offset: CGFloat) {
        let collapseThreshold: CGFloat = -56
        let expandThreshold: CGFloat = -8
        if offset < collapseThreshold && !filtersCollapsed {
            withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                filtersCollapsed = true
            }
        } else if offset > expandThreshold && filtersCollapsed {
            withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                filtersCollapsed = false
            }
        }
    }

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

    /// Builds one task row. Full reorder/drag affordances — same behavior
    /// as in the inline BacklogView: hover chevrons, drag-to-reorder,
    /// context menu. All rows are equal; order is dictated by the user's
    /// drag (or smart-sort, if enabled).
    @ViewBuilder
    private func row(for task: BacklogTask, hotKey: Int?, proposedSlot: Date? = nil) -> some View {
        BacklogFullscreenTaskRow(
            task: task,
            hotKey: hotKey,
            proposedSlot: proposedSlot,
            isUrgent: BacklogLogic.isUrgent(task),
            canMoveUp: canMoveUp(task),
            canMoveDown: canMoveDown(task),
            isFocused: focusedTaskId == task.id,
            defaultTaskDurationMinutes: optimizerService.defaultTaskDurationMinutes,
            selectionMode: selectionMode,
            isSelected: selectedTaskIds.contains(task.id),
            focusedTaskId: $focusedTaskId,
            onComplete: { complete(task) },
            onEdit: { onEditTask(task) },
            onDelete: { delete(task) },
            onFreeze: { freeze(task) },
            onReorderDrop: { dropped in
                handleReorderDrop(dropped: dropped, targetId: task.id)
            },
            onMoveUp: { moveTask(task, by: -1) },
            onMoveDown: { moveTask(task, by: +1) },
            onMoveToTop: { moveTaskToEdge(task, toTop: true) },
            onMoveToBottom: { moveTaskToEdge(task, toTop: false) },
            onFocusPrev: { focusRow(offsetFrom: task.id, by: -1) },
            onFocusNext: { focusRow(offsetFrom: task.id, by: +1) },
            onFindSlot: onScheduleTask.map { handler in { handler(task) } },
            onSetPreferredPeriod: { period in setPreferredPeriod(period, on: task) },
            onSplitTask: onSplitTask.map { handler in { handler(task) } },
            onSnoozeByDays: { days in snoozeTaskDeadline(task, byDays: days) },
            onReschedule: onRescheduleTask.map { handler in { handler(task) } },
            onSetDeadline: { deadlinePickerTask = task },
            onToggleUrgent: { toggleUrgent(task) },
            onLoadAlternatives: onLoadAlternativesForTask.map { handler in { await handler(task) } },
            onPickAlternative: onPickAlternativeScenario,
            onToggleSelection: { toggleSelection(task) }
        )
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
    private func exitSelection() {
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
    private var selectedTasks: [BacklogTask] {
        let ids = selectedTaskIds
        guard !ids.isEmpty else { return [] }
        return visibleTasks.filter { ids.contains($0.id) }
    }

    // MARK: - Bulk actions

    /// Schedule every selected pending task in one optimizer run.
    /// Reuses the same `onScheduleBacklog` callback that powers the
    /// header «Plan» pill — bulk-select is just a filtered view of
    /// «schedule the unscheduled set», so we don't need a separate
    /// per-task scheduling path. After dispatch we exit selection so
    /// the toast surfaces over the regular list.
    private func bulkSchedule() {
        Haptics.tap()
        let task = onScheduleBacklog
        exitSelection()
        guard let task else { return }
        Task { await task() }
    }

    /// Push every selected task's deadline forward by `days`. Mirrors
    /// the per-row «Snooze» behaviour but applied across the set in
    /// one undo unit. Tasks without an existing deadline get one
    /// computed from start-of-today + N days so the «defer» verb has
    /// a concrete meaning even on never-dated rows.
    private func bulkDefer(days: Int) {
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
        onUndoableAction?(label) { [backlogService] in
            for snapshot in snapshots {
                backlogService.updateTask(snapshot)
            }
        }
    }

    /// Freeze (set-aside) every selected task. Same non-destructive
    /// «park this for now» semantics as the per-row context menu, but
    /// applied as a single undoable batch. Frozen tasks leave the
    /// active list and unschedule their calendar slots — the optimizer
    /// stops planning around them.
    private func bulkFreeze() {
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
        onUndoableAction?(label) { [backlogService] in
            for snapshot in snapshots {
                backlogService.updateTask(snapshot)
                backlogService.unfreezeTask(id: snapshot.id)
            }
        }
    }

    /// Delete every selected task as one undoable batch. The undo
    /// closure restores each task at its original index so the user's
    /// drag-order is preserved across the round-trip — same contract
    /// as the per-row delete path.
    private func bulkDelete() {
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
        onUndoableAction?(label) { [backlogService] in
            // Restore in original-index order so earlier rows land
            // first and keep the storage sequence consistent for the
            // following `restoreTask` calls.
            for (task, index) in indexes.sorted(by: { ($0.1 ?? .max) < ($1.1 ?? .max) }) {
                backlogService.restoreTask(task, at: index)
            }
        }
    }

    // MARK: - Tombstones

/// Unfreeze a single task with an undo toast that re-freezes on tap.
    /// Same pattern as BacklogView, kept duplicated until the controllers
    /// themselves get extracted (out of scope for this refactor).
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

    private func unfreezeAllWithUndo() {
        let restoredIds = backlogService.frozen.map(\.id)
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.unfreezeAll()
        }
        onUndoableAction?("Unfroze \(restoredIds.count)\u{00A0}task\(restoredIds.count == 1 ? "" : "s")") { [backlogService] in
            for id in restoredIds { backlogService.freezeTask(id: id) }
        }
    }

// MARK: - Reorder helpers
    //
    // Mirror BacklogView's behaviour so users get identical reorder semantics
    // across the two surfaces.

    private func canMoveUp(_ task: BacklogTask) -> Bool {
        visibleTasks.first?.id != task.id
            && visibleTasks.contains(where: { $0.id == task.id })
    }

    private func canMoveDown(_ task: BacklogTask) -> Bool {
        visibleTasks.last?.id != task.id
            && visibleTasks.contains(where: { $0.id == task.id })
    }

    /// Move keyboard focus between visible rows. Boundaries clamp silently —
    /// no wrap-around. Identical to BacklogView so the two views share muscle
    /// memory.
    private func focusRow(offsetFrom currentId: String, by delta: Int) {
        let tasks = visibleTasks
        guard let idx = tasks.firstIndex(where: { $0.id == currentId }) else { return }
        let target = idx + delta
        guard target >= 0, target < tasks.count else { return }
        focusedTaskId = tasks[target].id
    }

    /// Reorder by ±1 slot via keyboard / context menu. Honours user-order
    /// only; in smart-sort mode the call still mutates storage order, but
    /// the visible position depends on the score — same as BacklogView.
    private func moveTask(_ task: BacklogTask, by delta: Int) {
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
        onUndoableAction?("Reordered \u{201C}\(task.title)\u{201D}") { [backlogService] in
            guard let previousIndex,
                  let current = backlogService.tasks.first(where: { $0.id == taskId })
            else { return }
            _ = backlogService.removeTask(id: taskId)
            backlogService.restoreTask(current, at: previousIndex)
        }
    }

    private func moveTaskToEdge(_ task: BacklogTask, toTop: Bool) {
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
        onUndoableAction?("Moved \u{201C}\(task.title)\u{201D} to \(toTop ? "top" : "bottom")") { [backlogService] in
            guard let previousIndex,
                  let current = backlogService.tasks.first(where: { $0.id == taskId })
            else { return }
            _ = backlogService.removeTask(id: taskId)
            backlogService.restoreTask(current, at: previousIndex)
        }
    }

    /// Drop one task onto another to reorder. If the dropped task and the
    /// target live in different context groups, the dropped task adopts the
    /// target's context (otherwise grouping would silently undo the visual
    /// move). Mirrors BacklogView's `handleReorderDrop` 1:1.
    private func handleReorderDrop(dropped: BacklogTaskDrag, targetId: String) {
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
        onUndoableAction?(
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

    // MARK: - Actions

    /// Open the compact creation form with whatever's been typed so far.
    /// Mirrors `BacklogView.openCreateWithDetails` so both backlog modes
    /// share the same ⇧↩ / "›" affordance behaviour.
    private func openCreateWithDetails() {
        let parsed = parsedNewTaskTitle
        guard let onCreateTaskWithDetails else {
            addTask()
            return
        }
        let title = parsed.cleaned
        let duration = parsed.durationMinutes
            ?? BacklogTitleParser.guessDuration(for: title)
        onCreateTaskWithDetails(title, duration)
        newTaskTitle = ""
        parsedNewTaskTitle = ("", nil)
        isInputFocused = false
    }

    private func addTask() {
        let parsed = parsedNewTaskTitle
        let title = parsed.cleaned
        guard !title.isEmpty else { return }

        // Same duration priority as the inline `BacklogView`:
        // explicit parse > machine verb-guess > user default.
        let duration = parsed.durationMinutes
            ?? BacklogTitleParser.guessDuration(for: title)
            ?? optimizerService.defaultTaskDurationMinutes

        // Match inline `BacklogView`: stamp the active project's name on
        // `context` so the task lands in the user's current view (local
        // Bubo projects need this — EK lists historically got it from
        // the Reminders round-trip).
        let task = BacklogTask(
            title: title,
            durationMinutes: duration,
            priority: .medium,
            context: activeProjectName
        )
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.addTask(task)
        }
        newTaskTitle = ""
        parsedNewTaskTitle = ("", nil)
    }

    private func complete(_ task: BacklogTask) {
        // Tap-to-complete via checkbox already fires `Haptics.tap()` from
        // the press itself (`BacklogTaskRow.checkbox` + `IconPressStyle`),
        // so no haptic here. Hot-key completion (digits 1-9) is the other
        // entry path; the haptic for that case fires from the digit-shortcut
        // button before delegating into `complete(_:)`.
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.entrance, reduceMotion: reduceMotion)) {
            backlogService.completeTask(id: task.id)
        }
        onUndoableAction?("Completed \u{201C}\(task.title)\u{201D}") { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    private func delete(_ task: BacklogTask) {
        let originalIndex = backlogService.indexOfTask(id: task.id)
        _ = backlogService.removeTask(id: task.id)
        onUndoableAction?("\u{201C}\(task.title)\u{201D} deleted") { [backlogService] in
            backlogService.restoreTask(task, at: originalIndex)
        }
    }

    private func freeze(_ task: BacklogTask) {
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.freezeTask(id: task.id)
        }
        onUndoableAction?("Froze \u{201C}\(task.title)\u{201D}") { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    /// Update a task's deadline via the inline picker. Mirrors
    /// `BacklogView.updateTaskDeadline` so both backlog modes share the
    /// same undo + toast pipeline.
    private func updateTaskDeadline(task: BacklogTask, to newDeadline: Date?) {
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
        onUndoableAction?(label) { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    /// Toggle urgent state via today-end deadline. Mirrors the inline
    /// `BacklogView.toggleUrgent` so the context-menu acts identically in
    /// both modes.
    private func toggleUrgent(_ task: BacklogTask) {
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
        onUndoableAction?(label) { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    private func uncomplete(_ task: BacklogTask) {
        var restored = task
        restored.status = .pending
        restored.completedAt = nil
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.updateTask(restored)
        }
    }
}

// `BacklogScrollOffsetKey` extracted to its own file
// (`Views/BacklogScrollOffsetKey.swift`).
