import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Task List Expansion

/// Three-state disclosure for the Tasks card.
///
/// - `.collapsed`: только хедер, список полностью скрыт.
/// - `.compact`: максимум 4 строки видны, остальные — внутренним скроллом.
///   Сохраняет место под таймлайн ниже карточки.
/// - `.expanded`: полностью раскрыт до `fullyExpandedMaxHeight`, пользователь
///   осознанно жертвует видимостью таймлайна ради полного списка.
///
/// Birman: один триггер (шеврон) переключает состояния — без дублирующих
/// кнопок «Show more» / «Show fewer».
enum TaskListExpansion: Equatable, Hashable {
    case collapsed
    case compact
    case expanded

    /// Next state in the round-trip cycle.
    var next: TaskListExpansion {
        switch self {
        case .collapsed: return .compact
        case .compact:   return .expanded
        case .expanded:  return .collapsed
        }
    }

    /// SF Symbol for the disclosure chevron.
    /// One arrow = стандартное раскрытие; двойная стрелка = «раскрыто
    /// полностью».
    var iconName: String {
        switch self {
        case .collapsed: return "chevron.right"
        case .compact:   return "chevron.down"
        case .expanded:  return "chevron.down.2"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .collapsed: return "Show tasks"
        case .compact:   return "Show all tasks"
        case .expanded:  return "Hide tasks"
        }
    }
}

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
    var onScheduleTasks: () -> Void
    var onDeleteTask: ((BacklogTask) -> Void)?
    /// Fired for any reversible user action (reorder, complete, cross-context
    /// drop) so the parent can surface a unified undo toast — it owns
    /// `ToastState`. nil silently disables the toast; the action still runs.
    ///
    /// HIG: every destructive or hard-to-discover action gets an undo path.
    /// Birman: undo instead of confirmation dialogs.
    var onUndoableAction: ((_ message: String, _ undo: @escaping () -> Void) -> Void)? = nil
    /// External trigger: set to `true` to focus the "Add task…" field.
    /// BacklogView resets it to `false` after grabbing focus.
    @Binding var focusRequested: Bool
    /// When true, the task list expands automatically on appear if tasks exist.
    /// Used in the empty-calendar state where tasks are the primary content.
    var autoExpand: Bool = false

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Shared drag + ghost-preview state, injected by `MenuBarView` via the
    /// environment. May be nil in previews / settings panes, in which case
    /// the ghost-block and drag-highlighting features silently degrade to
    /// inline text and per-row targeting.
    @Environment(\.backlogCoordinator) private var coordinator

    @State private var newTaskTitle = ""
    /// Three-state disclosure for the task list.
    /// Birman: «информация важнее украшений» — шеврон сам несёт три смысла
    /// (collapsed / compact / expanded), без дублирующей кнопки «Show more».
    @State private var expansion: TaskListExpansion = .collapsed
    @State private var editingTaskId: String? = nil
    /// Snapshot of `expansion` captured the moment inline edit begins so we
    /// can restore it when the user finishes editing. Editing forces the
    /// list into `.expanded` to give the form room to breathe (HIG: don't
    /// make the user scroll to see the field they're filling).
    @State private var expansionBeforeEdit: TaskListExpansion? = nil
    /// Snapshot of `expansion` captured the moment a drag starts. Same
    /// idea as `expansionBeforeEdit`: during a drag the list flips to
    /// `.expanded` so the user sees every reorder target at once, and the
    /// pre-drag state is restored when the drag ends. Decoupled from
    /// `expansionBeforeEdit` because the two can nest (user starts editing,
    /// then drags a row from inside the edit session).
    @State private var expansionBeforeDrag: TaskListExpansion? = nil
    /// Measured height of the hosting popover. Drives the dynamic ceiling
    /// for the fully-expanded and editing states so large screens are not
    /// forced into a 480pt cap. Zero until the first layout pass.
    @State private var measuredHostHeight: CGFloat = 0
    /// Hover state for the Schedule pill — HIG: primary actions should read as
    /// buttons, so a subtle capsule фон появляется на наведении.
    @State private var isScheduleHovering: Bool = false
    /// Textual ghost — complements the ghost block on the timeline so
    /// assistive technologies and compact layouts still get "Today 14:00".
    @State private var ghostPreviewText: String? = nil
    @State private var ghostPreviewTask: Task<Void, Never>? = nil
    @FocusState private var isInputFocused: Bool
    /// Row-level keyboard focus. `nil` when no row owns focus (e.g., input
    /// field is focused instead). Driven by ↑ / ↓ in rows and by clicks.
    @FocusState private var focusedTaskId: String?
    /// Whether the "N completed today" tombstone is expanded. Collapsed by
    /// default so finished work doesn't crowd the active list.
    @State private var showCompletedToday: Bool = false
    /// Whether the frozen tombstone is expanded. Same pattern as
    /// `showCompletedToday`: summary row always visible, the list stays
    /// collapsed until the user asks.
    @State private var showFrozen: Bool = false
    /// Sprint mode: collapses grouping, dims metadata, shows only the top
    /// `Self.sprintModeMaxTasks` rows in a bigger type size. One thing on
    /// screen at a time — Birman's «режим кассы».
    @State private var isSprintMode: Bool = false
    /// Smart Sort: arranges active tasks by (deadline urgency + priority)
    /// instead of user drag order. Survives per session only — the stored
    /// order remains the user's canonical sequence.
    @State private var useSmartSort: Bool = false
    /// Urgent-only filter: narrows the visible list to tasks whose deadline
    /// falls within `isUrgent`'s window. Toggled by tapping the red «N urgent»
    /// counter in the header — Бирман: «информация, а не украшение».
    /// Session-local only; survives popover close, not app restart.
    @State private var urgentOnlyFilter: Bool = false

    /// Cached "where would this land?" answer per task ID. Populated lazily
    /// on first hover — the lookup runs the same `FreeSlotFinder.nextSlot`
    /// that drives the ghost preview for new tasks, so the two signals agree.
    @State private var rowSlotPreviews: [String: String] = [:]
    /// In-flight debounced lookups keyed by task ID so we can cancel a pending
    /// compute if the cursor leaves the row before the result arrives.
    @State private var rowSlotPreviewTasks: [String: Task<Void, Never>] = [:]

    /// User has already performed at least one drag — used to hide the
    /// onboarding hint once the affordance has been discovered.
    @AppStorage("BuboBacklogHasDragged") private var hasDragged: Bool = false

    /// Default duration applied to new tasks (before parsing).
    /// Kept as a constant so tests and the ghost preview agree.
    static let defaultTaskDurationMinutes: Int = 60

    /// Maximum number of task rows visible in the compact expansion state.
    /// A height-capped ScrollView keeps the timeline reachable.
    private static let maxExpandedTasks = 4

    /// Floor for the fully-expanded state on small hosts. The effective
    /// cap is `dynamicExpandedMaxHeight` — this constant only kicks in when
    /// the host height is unknown (first layout, previews).
    private static let fullyExpandedMaxHeight: CGFloat = 480

    /// Vertical space we reserve for header + input field + ghost-preview
    /// row + card padding when sizing the list against the host. Leaves the
    /// timeline below visible even when the list is fully expanded.
    private static let nonListReservedHeight: CGFloat = 220

    /// Ceiling for the fully-expanded list, derived from the measured host
    /// height so large popovers get a tall list and small hosts stay honest.
    /// Falls back to `fullyExpandedMaxHeight` before the first layout pass.
    private var dynamicExpandedMaxHeight: CGFloat {
        guard measuredHostHeight > 0 else { return Self.fullyExpandedMaxHeight }
        return max(
            Self.fullyExpandedMaxHeight,
            measuredHostHeight - Self.nonListReservedHeight
        )
    }

    /// Taller ceiling used while a task is being inline-edited. The edit
    /// card itself is ~350–450pt tall; without the extra headroom the user
    /// has to scroll inside the list to see the fields they're filling.
    private var editingMaxHeight: CGFloat {
        guard measuredHostHeight > 0 else { return Self.fullyExpandedMaxHeight + 200 }
        // Reserve less space under the list during edit (the timeline is
        // less relevant while the user is heads-down on a task).
        return max(
            Self.fullyExpandedMaxHeight + 200,
            measuredHostHeight - 140
        )
    }

    /// Single-line row height. Lower than the former 44pt because the row
    /// is now one line (title + inline middot-separated metadata) instead
    /// of a two-line stack.
    static let compactRowHeight: CGFloat = 40

    /// Hard cap on rows visible in sprint mode. Small on purpose: the whole
    /// point of the mode is to see exactly what's next without a scroll.
    static let sprintModeMaxTasks = 5

    /// All non-done, non-frozen tasks — the "real" active set used for
    /// totals, capacity math and onAppear heuristics. Not subject to the
    /// urgent-only UI filter, so the header counter doesn't lie about
    /// what's actually in the backlog.
    private var allActiveTasks: [BacklogTask] {
        // Frozen tasks live in their own tombstone below — excluding them
        // here keeps the active list's count, sort and rendering honest.
        backlogService.tasks.filter { $0.status != .done && $0.status != .frozen }
    }

    /// Tasks visible in the list. Equals `allActiveTasks` unless the
    /// urgent-only filter is engaged, in which case only tasks whose
    /// deadline falls inside the urgency window survive. Keeping the
    /// filter here (not in the service) means the storage order stays
    /// the user's canonical sequence.
    private var activeTasks: [BacklogTask] {
        guard urgentOnlyFilter else { return allActiveTasks }
        return allActiveTasks.filter { isUrgent($0) }
    }

    /// Deadline-urgency + priority score. Higher = more urgent.
    /// Today / overdue dominates, tomorrow is a strong second, week-out is
    /// a nudge; without a deadline, only priority contributes. Weighted so
    /// "high priority, no deadline" still outranks "low priority, week out".
    private func smartScore(for task: BacklogTask) -> Double {
        var score = task.priority.numericValue * 100
        if let deadline = task.deadline {
            let cal = Calendar.current
            if deadline < Date() || cal.isDateInToday(deadline) {
                score += 1000
            } else if cal.isDateInTomorrow(deadline) {
                score += 500
            } else {
                let days = max(1, cal.dateComponents([.day], from: Date(), to: deadline).day ?? 7)
                score += max(0, 300 - Double(days) * 20)
            }
        }
        return score
    }

    /// Active tasks as a flat list ordered by `smartScore`. Stable for equal
    /// scores: falls back to the user's storage order, so the sorted list
    /// never "shuffles" two tasks the user tied deliberately.
    private var smartSortedActiveTasks: [BacklogTask] {
        let indexed = activeTasks.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            let lScore = smartScore(for: lhs.1)
            let rScore = smartScore(for: rhs.1)
            if lScore == rScore { return lhs.0 < rhs.0 }
            return lScore > rScore
        }
        return sorted.map { $0.1 }
    }

    /// Tasks completed since local midnight. Powers the «N completed today»
    /// tombstone — HIG/Birman: сохраняем контекст «сколько сделано сегодня»,
    /// но квартирантом, не жильцом: свёрнуто по умолчанию.
    private var completedToday: [BacklogTask] {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return backlogService.tasks
            .filter { $0.status == .done }
            .filter { ($0.completedAt ?? .distantPast) >= startOfDay }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// Height cap for the task list ScrollView.
    ///
    /// - `.compact`: sums the first `maxExpandedTasks` row heights so the
    ///   visible area always fits 4 task rows, keeping the timeline reachable.
    /// - `.expanded`: `min(contentHeight, fullyExpandedMaxHeight)` — shows
    ///   every task up to a generous cap, longer lists scroll internally.
    /// - `.collapsed`: zero (list hidden entirely).
    private var scrollMaxHeight: CGFloat {
        // Single-line row — see `compactRowHeight`. No extra inter-row
        // spacing since the VStack uses spacing=0.
        let rowHeight = Self.compactRowHeight
        let activeCount = activeTasks.count
        // Allow room for each tombstone header (chevron + count row) so
        // "N completed today" and "N frozen" stay reachable even when the
        // active list is empty — previously the 0-tasks case collapsed the
        // ScrollView to height 0 and hid both tombstones below it.
        let tombstoneHeaderHeight: CGFloat = 28
        let hasCompleted = !completedToday.isEmpty
        let hasFrozen = !backlogService.frozen.isEmpty
        let tombstoneMin: CGFloat = (hasCompleted ? tombstoneHeaderHeight : 0)
            + (hasFrozen ? tombstoneHeaderHeight : 0)

        guard activeCount > 0 || tombstoneMin > 0 else { return 0 }

        // While inline-editing, the edit card takes the place of a row and
        // is several hundred points tall. Use a taller ceiling and skip the
        // compact cap entirely so the form isn't clipped. The list still
        // caps at `editingMaxHeight` so something of the footer stays
        // reachable for users who want to click Add at the bottom.
        if editingTaskId != nil {
            // Rough budget: the edit card (~420pt) + remaining rows.
            let editCardHeight: CGFloat = 420
            let otherRows = max(0, activeCount - 1)
            let content = editCardHeight + rowHeight * CGFloat(otherRows) + tombstoneMin
            return min(content, editingMaxHeight)
        }

        switch expansion {
        case .collapsed:
            return 0
        case .compact:
            let visible = min(activeCount, Self.maxExpandedTasks)
            return rowHeight * CGFloat(visible) + tombstoneMin
        case .expanded:
            let content = rowHeight * CGFloat(activeCount) + tombstoneMin
            return min(content, dynamicExpandedMaxHeight)
        }
    }

    /// Duration to use for ghost-preview lookup and for the task actually
    /// created on submit. Reparses on every keystroke.
    private var parsedDurationMinutes: Int {
        BacklogTitleParser.parse(newTaskTitle).durationMinutes ?? Self.defaultTaskDurationMinutes
    }

    /// Same as `parsedDurationMinutes` but returns `nil` when the parser
    /// didn't recognize an explicit duration. Drives the inline chip that
    /// echoes what the parser understood — seeing "30 min" appear confirms
    /// the shorthand was caught before the user commits.
    private var recognizedDurationMinutes: Int? {
        BacklogTitleParser.parse(newTaskTitle).durationMinutes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header + list stay visible as long as *any* bucket has tasks
            // (active, completed-today, or frozen). Otherwise the user's
            // last completion would make the tombstone unreachable — it
            // would render inside a hidden subtree, and "undo by clicking
            // the checkmark" would be gone.
            // Use `allActiveTasks` so the urgent-only filter can't hide the
            // header — the user needs a way to flip the filter back off even
            // when no urgent tasks match.
            if !allActiveTasks.isEmpty
                || isInputFocused
                || !completedToday.isEmpty
                || !backlogService.frozen.isEmpty {
                backlogHeader
                // Task rows only appear when expanded (up to 4 visible
                // with scroll); collapsed = header only.
                taskList
            }
            addTaskField
            ghostPreviewRow
        }
        // Measure the hosting popover height so the fully-expanded list can
        // grow on big screens instead of being pinned to 480pt. We sample
        // via `NSApp.windows` lazily (not a GeometryReader on self, which
        // would cycle: list height → host height → list height).
        .background(hostHeightProbe)
        .onChange(of: editingTaskId) { oldValue, newValue in
            // Remember where the user was before entering edit, then force
            // the list into `.expanded` so the form has room. On exit,
            // restore the captured state — without this, finishing an edit
            // could leave the card collapsed with the cursor hanging in
            // empty space.
            if oldValue == nil, newValue != nil {
                expansionBeforeEdit = expansion
                withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                    if expansion == .collapsed { expansion = .expanded }
                }
            } else if oldValue != nil, newValue == nil {
                if let previous = expansionBeforeEdit {
                    withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                        expansion = previous
                    }
                }
                expansionBeforeEdit = nil
            }
        }
        .onChange(of: focusRequested) { _, requested in
            if requested {
                isInputFocused = true
                focusRequested = false
            }
        }
        // Any backlog edit (duration, context) or event change invalidates
        // the hover-preview cache — otherwise a row that was edited 10s ago
        // could keep showing a slot computed against a stale duration. The
        // count + sum is a cheap fingerprint: changes whenever any task
        // grows or shrinks, reschedules, or is added/removed.
        .onChange(of: taskHoverCacheFingerprint) { _, _ in
            rowSlotPreviews.removeAll()
            for (_, task) in rowSlotPreviewTasks { task.cancel() }
            rowSlotPreviewTasks.removeAll()
        }
        // Drag = focus mode. The moment the user grabs a task:
        //   • Tasks flip to `.expanded` — every other row becomes a
        //     legitimate reorder target, visible at once.
        //   • EventRowView listens to the same flag and compresses itself
        //     to a single-line sliver, so the timeline below becomes a
        //     column of highlighted free slots with thin booked-time
        //     dividers between them. See `EventRowView.isCompressedForDrag`.
        // Pre-drag expansion is restored on drop/cancel.
        .onChange(of: coordinator?.isDraggingTask ?? false) { _, dragging in
            if dragging {
                // Only snapshot the first time a drag starts while we're
                // idle. Don't overwrite a snapshot if (somehow) the flag
                // toggles mid-session — the first pre-drag state is what
                // we want to return to.
                if expansionBeforeDrag == nil {
                    expansionBeforeDrag = expansion
                }
                if expansion != .expanded {
                    withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                        expansion = .expanded
                    }
                }
            } else {
                if let snapshot = expansionBeforeDrag {
                    withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                        expansion = snapshot
                    }
                    expansionBeforeDrag = nil
                }
            }
        }
        .onChange(of: isInputFocused) { _, focused in
            // Hide the ghost block the moment the user tabs away from the
            // input — otherwise it would linger on the timeline even though
            // nothing is currently being composed.
            if !focused {
                coordinator?.clearGhost()
                ghostPreviewText = nil
                ghostPreviewTask?.cancel()
            }
        }
        .onAppear {
            if autoExpand && !allActiveTasks.isEmpty {
                expansion = .compact
            }
            // Tombstones (completed-today, frozen) live inside the
            // ScrollView, which is hidden while `expansion == .collapsed`.
            // If the user returns to a state with zero active tasks but
            // non-empty tombstones, auto-open to `.compact` so the history
            // stays reachable — otherwise the chevron is the only clue
            // anything survived.
            if allActiveTasks.isEmpty,
               !completedToday.isEmpty || !backlogService.frozen.isEmpty,
               expansion == .collapsed {
                expansion = .compact
            }
        }
        .onChange(of: allActiveTasks.count) { _, newCount in
            // Same auto-open rule on live state changes: the last active
            // task just got completed and we still have tombstones — pop
            // the list open so the user sees what happened. Based on
            // `allActiveTasks` so toggling the urgent-only filter doesn't
            // trigger false positives.
            if newCount == 0,
               !completedToday.isEmpty || !backlogService.frozen.isEmpty,
               expansion == .collapsed {
                withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                    expansion = .compact
                }
            }
            // If the user had `urgentOnlyFilter` engaged and the urgent set
            // dries up (last urgent task completed), automatically disengage
            // so the filter doesn't strand the user in an empty view.
            if urgentOnlyFilter, activeTasks.isEmpty {
                urgentOnlyFilter = false
            }
        }
        .onDisappear {
            coordinator?.clearGhost()
            coordinator?.endDrag()
            ghostPreviewTask?.cancel()
            cancelAllRowSlotPreviews()
        }
    }

    /// Invisible background view that reads the hosting window's visible
    /// height on appear. Plain AppKit — a GeometryReader rooted here would
    /// report the BacklogView's own height, which is the value we're trying
    /// to compute, so that would cycle. The window height is stable across
    /// a session; we re-sample on appear to handle "user resized popover".
    private var hostHeightProbe: some View {
        Color.clear
            .onAppear {
                #if canImport(AppKit)
                if let window = NSApp.windows.filter({ $0.isVisible })
                    .max(by: { $0.frame.height < $1.frame.height }) {
                    measuredHostHeight = window.contentView?.bounds.height
                        ?? window.frame.height
                }
                #endif
            }
    }

    // MARK: - Header

    private var backlogHeader: some View {
        let totalCount = allActiveTasks.count
        let urgentCount = backlogService.urgent(withinDays: 2).count

        return HStack(spacing: DS.Spacing.sm) {
            // Capacity ring FIRST — it answers the main question «влезет
            // ли сегодня» и раньше терялось между иконок справа. HIG: put
            // glanceable status where the eye lands first, not buried in
            // trailing controls. Birman: кольцо — это первая «подпись» к
            // слову Tasks, не украшение на периферии.
            if totalCount > 0 {
                BacklogCapacityRing(
                    pendingMinutes: pendingWorkloadMinutes,
                    remainingWorkdayMinutes: remainingWorkdayMinutes
                )
                .help(capacityRingTooltip)
            }

            Button {
                withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                    expansion = expansion.next
                }
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: expansion.iconName)
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text("Tasks")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(skin.resolvedTextPrimary)

                    // Total count — always shown, tabular digits so the number
                    // doesn't jitter horizontally when `.numericText()` rolls.
                    Text("\(totalCount)")
                        .font(.subheadline.weight(.regular).monospacedDigit())
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .contentTransition(.numericText())
                }
            }
            .buttonStyle(.plain)
            .help(expansion.accessibilityHint)

            // Urgent-count pill — now a real control. Clicking it toggles
            // the urgent-only filter. Middot separator visually attaches it
            // to the total count without the two numbers fighting.
            // Birman: «информация — это кнопка», иначе это просто краска.
            if urgentCount > 0 {
                urgentFilterButton(urgentCount: urgentCount)
            }

            Spacer()

            if totalCount > 0 {
                // Overflow menu holds smart-sort + sprint (was: two cryptic
                // icon buttons). HIG: secondary actions without a clear
                // glyph belong in a menu with labels. One icon in the header
                // + named actions in the dropdown is both calmer and more
                // discoverable.
                headerOverflowMenu
                scheduleButton
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.sm)
    }

    /// Red «N urgent» pill — acts as a filter toggle. Selected state gets a
    /// filled background so the user can see the filter is engaged; a
    /// second click releases it. Hidden entirely when no urgent tasks exist.
    @ViewBuilder
    private func urgentFilterButton(urgentCount: Int) -> some View {
        Button {
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                urgentOnlyFilter.toggle()
                // Engaging the filter while the list is collapsed would hide
                // everything — open to `.compact` so the filtered set is
                // immediately visible.
                if urgentOnlyFilter, expansion == .collapsed {
                    expansion = .compact
                }
            }
        } label: {
            HStack(spacing: DS.Spacing.xxs) {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
                Text("\(urgentCount) urgent")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(skin.resolvedDestructiveColor)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xxs)
            .background(
                Capsule().fill(
                    skin.resolvedDestructiveColor
                        .opacity(urgentOnlyFilter ? DS.Opacity.lightFill : 0)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    skin.resolvedDestructiveColor.opacity(urgentOnlyFilter ? DS.Opacity.softAccent : 0),
                    lineWidth: DS.Border.thin
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(urgentOnlyFilter ? "Show all tasks" : "Show only urgent tasks")
        .accessibilityLabel(
            urgentOnlyFilter
                ? "Showing only urgent tasks — tap to clear filter"
                : "\(urgentCount) urgent tasks — tap to filter"
        )
    }

    /// Overflow menu — the single home for secondary view controls
    /// (smart-sort, sprint mode). Previously these were two bare icon
    /// buttons in the header; Бирман: «пиктограмма без подписи —
    /// загадка». Inside the menu each action gets a real verb and
    /// active state shows the SF Symbol swap.
    private var headerOverflowMenu: some View {
        Menu {
            Button {
                withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                    useSmartSort.toggle()
                    if useSmartSort, expansion == .collapsed {
                        expansion = .compact
                    }
                }
            } label: {
                Label(
                    useSmartSort ? "Show in user order" : "Smart sort",
                    systemImage: useSmartSort ? "wand.and.stars" : "arrow.up.arrow.down"
                )
            }

            Button {
                withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                    isSprintMode.toggle()
                    if isSprintMode, expansion == .collapsed {
                        expansion = .compact
                    }
                }
            } label: {
                Label(
                    isSprintMode ? "Exit sprint mode" : "Sprint mode",
                    systemImage: isSprintMode ? "bolt.fill" : "bolt"
                )
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption)
                .foregroundStyle(skin.resolvedTextSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More options")
        .accessibilityLabel("More task list options")
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

    /// Remaining minutes between "now" and the end of the working day.
    /// Clamped to zero past the workday so the ring stays at 100% after hours
    /// instead of going negative. Uses `OptimizerService.workingHours` — the
    /// same source of truth as the free-slot finder.
    private var remainingWorkdayMinutes: Int {
        let cal = Calendar.current
        let now = Date()
        let endHour = optimizerService.workingHours.upperBound
        guard let endOfWorkday = cal.date(
            bySettingHour: endHour,
            minute: 0,
            second: 0,
            of: now
        ) else { return 0 }
        let seconds = max(0, endOfWorkday.timeIntervalSince(now))
        return Int(seconds / 60)
    }

    private var capacityRingTooltip: String {
        let workload = pendingWorkloadMinutes
        let remaining = remainingWorkdayMinutes
        return "Backlog: \(DS.formatMinutes(workload)); remaining today: \(DS.formatMinutes(remaining))"
    }

    /// HIG: главное действие должно читаться как кнопка и в покое, не только
    /// на hover. Subtle fill + hairline border = affordance без тяжёлой
    /// заливки; оба канала усиливаются на hover, так что жест наведения
    /// остаётся информативным.
    private var scheduleButton: some View {
        Button {
            onScheduleTasks()
        } label: {
            Text("Schedule")
                .font(.caption.weight(.medium))
                .foregroundStyle(skin.accentColor)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .background {
                    Capsule()
                        .fill(skin.accentColor.opacity(isScheduleHovering ? 0.16 : DS.Opacity.lightFill))
                }
                .overlay {
                    Capsule()
                        .strokeBorder(
                            skin.accentColor.opacity(isScheduleHovering ? DS.Opacity.softAccent : DS.Opacity.subtleBorder),
                            lineWidth: DS.Border.thin
                        )
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                isScheduleHovering = hovering
            }
        }
    }

    // MARK: - Task List
    //
    // Three-state disclosure, driven by `expansion`:
    //
    // - .collapsed: no task rows — only the header is visible,
    //   keeping the card minimal.
    // - .compact: a height-capped ScrollView, ~4 rows visible, the rest
    //   reached by internal scroll. Preserves the timeline strip below.
    // - .expanded: cap raised to `fullyExpandedMaxHeight` (~10–11 rows);
    //   the user explicitly traded timeline space for full visibility.
    //
    // Birman: один шеврон-триггер несёт все три смысла, без дублирующей
    // кнопки «Show more».

    private var taskList: some View {
        // Discoverability hint ("drag onto a free slot") used to live here
        // as a fat banner above the task list. It now appears contextually,
        // on hover, as a caption inside the `FreeSlotRow` — Бирман: «покажите
        // пример там, где действие происходит, не инструкцию где-то сверху».
        // See `FreeSlotRow.canShowDragHint`.
        VStack(spacing: 0) {
            if expansion != .collapsed {
                ScrollView {
                    VStack(spacing: 0) {
                        taskRowsContent(visibleIDs: nil)
                        completedTombstone
                        frozenTombstone
                    }
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: scrollMaxHeight)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .motionAwareAnimation(DS.Animation.standard, value: activeTasks.map(\.id), reduceMotion: reduceMotion)
        .motionAwareAnimation(DS.Animation.standard, value: expansion, reduceMotion: reduceMotion)
    }

    /// Renders grouped task rows. When `visibleIDs` is nil all tasks
    /// are rendered; otherwise only tasks whose id is in the set appear.
    ///
    /// Context-group headers are intentionally hidden: a single typographic
    /// voice for the list reduces visual competition with task titles.
    /// Grouping still drives ordering via `groupedByContext`, and each row
    /// already surfaces its context in the subtitle.
    @ViewBuilder
    private func taskRowsContent(visibleIDs: Set<String>?) -> some View {
        // Three rendering strategies:
        // 1. Smart Sort on — flat list ordered by `smartScore`, grouping
        //    dropped so the queue reads as a single priority list.
        // 2. Sprint mode on — same flat list, capped at `sprintModeMaxTasks`
        //    (combined with Smart Sort if both are enabled).
        // 3. Default — user's drag order honoured via `groupedByContext`.
        //
        // When a `visibleIDs` set is passed, only those tasks render — used
        // by animations that reveal one row at a time.
        let baseOrder: [BacklogTask] = useSmartSort ? smartSortedActiveTasks : activeTasks
        let capped: [BacklogTask] = isSprintMode ? Array(baseOrder.prefix(Self.sprintModeMaxTasks)) : baseOrder
        let ids: Set<String> = visibleIDs ?? Set(capped.map(\.id))

        // When Smart Sort OR Sprint Mode is on, skip grouping entirely — one
        // flat list reads truer for both modes. Otherwise fall through to
        // `groupedByContext`, which preserves context clustering.
        if useSmartSort || isSprintMode {
            ForEach(capped) { task in
                if ids.contains(task.id) {
                    taskRowBody(task)
                }
            }
        } else {
            let grouped = backlogService.groupedByContext
            ForEach(grouped, id: \.context) { group in
                ForEach(group.tasks) { task in
                    if ids.contains(task.id) {
                        taskRowBody(task)
                    }
                }
            }
        }
    }

    /// Either the inline edit form (when this row is being edited) or the
    /// read-only `BacklogTaskRow`. Extracted so the grouped and flat
    /// rendering paths in `taskRowsContent` don't duplicate 40 lines of
    /// parameter plumbing.
    @ViewBuilder
    private func taskRowBody(_ task: BacklogTask) -> some View {
        if editingTaskId == task.id {
            BacklogTaskEditRow(
                task: task,
                backlogService: backlogService,
                onDone: { editingTaskId = nil }
            )
            .transition(.opacity)
        } else {
            BacklogTaskRow(
                task: task,
                isUrgent: isUrgent(task),
                isDragging: coordinator?.draggedTask?.taskId == task.id,
                canMoveUp: canMoveUp(task),
                canMoveDown: canMoveDown(task),
                isSprintMode: isSprintMode,
                onComplete: { completeTaskWithUndo(task) },
                onEdit: { editingTaskId = task.id },
                onDelete: { onDeleteTask?(task) },
                onFreeze: { freezeTaskWithUndo(task) },
                onDragStart: {
                    coordinator?.beginDrag(payload(for: task))
                    if !hasDragged { hasDragged = true }
                },
                onDragEnd: { coordinator?.endDrag() },
                onReorderDrop: { dropped in
                    handleReorderDrop(dropped: dropped, targetId: task.id)
                },
                onMoveUp: { moveTask(task, by: -1) },
                onMoveDown: { moveTask(task, by: +1) },
                onMoveToTop: { moveTaskToEdge(task, toTop: true) },
                onMoveToBottom: { moveTaskToEdge(task, toTop: false) },
                isFocused: focusedTaskId == task.id,
                onFocusPrev: { focusRow(offsetFrom: task.id, by: -1) },
                onFocusNext: { focusRow(offsetFrom: task.id, by: +1) },
                slotPreview: rowSlotPreviews[task.id],
                onHoverChanged: { hovering in
                    handleRowHover(task: task, hovering: hovering)
                }
            )
            .focusable()
            .focused($focusedTaskId, equals: task.id)
            .focusEffectDisabled()
            .transition(.opacity.combined(with: .move(edge: .leading)))
        }
    }

    // MARK: - Completed-today tombstone

    /// «N completed today» summary + optional expanded list of completed rows.
    /// Hidden entirely when no tasks were completed today so it doesn't add
    /// visual weight to the empty state.
    ///
    /// Birman: «квартирант, а не жилец» — свёрнуто по умолчанию; клик на
    /// заполненный чекбокс возвращает задачу обратно в активный список.
    @ViewBuilder
    private var completedTombstone: some View {
        if !completedToday.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                        showCompletedToday.toggle()
                    }
                } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: showCompletedToday ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .contentTransition(.symbolEffect(.replace))
                        Text("\(completedToday.count) completed today")
                            .font(.caption2.monospacedDigit())
                            .contentTransition(.numericText())
                        Spacer()
                    }
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .padding(.horizontal, DS.Spacing.xs)
                    .padding(.vertical, DS.Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(completedToday.count) tasks completed today")
                .accessibilityHint(showCompletedToday ? "Hide completed" : "Show completed")

                if showCompletedToday {
                    ForEach(completedToday) { task in
                        completedRow(task)
                            .transition(.opacity)
                    }
                }
            }
            .motionAwareAnimation(DS.Animation.standard, value: showCompletedToday, reduceMotion: reduceMotion)
            .motionAwareAnimation(DS.Animation.quick, value: completedToday.map(\.id), reduceMotion: reduceMotion)
        }
    }

    /// One completed-task row. Filled checkmark, dimmed strike-through title.
    /// Tapping the checkmark restores the task to the active list.
    @ViewBuilder
    private func completedRow(_ task: BacklogTask) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            // Reserve the same leading gutter as active rows so the checkmark
            // column aligns vertically — keeps the two lists visually linked.
            Color.clear
                .frame(width: DS.Size.iconLarge, height: DS.Size.accentBarHeight)

            Button {
                uncompleteTask(task)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Restore task")
            .accessibilityLabel("Restore \u{201C}\(task.title)\u{201D}")

            Text(task.title)
                .font(.callout)
                .foregroundStyle(skin.resolvedTextTertiary)
                .strikethrough()
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.xs)
        .frame(minHeight: Self.compactRowHeight)
    }

    // MARK: - Frozen tombstone

    /// «N frozen» summary + on-demand list of frozen tasks. Follows the same
    /// "квартирант, а не жилец" pattern as `completedTombstone`: hidden when
    /// empty, collapsed by default, one tap expands.
    ///
    /// The header carries an "Unfreeze all" shortcut — frozen tasks are often
    /// batch-thawed when priorities shift, and clicking ✕ on each pill would
    /// be friction the non-destructive freeze is trying to avoid.
    @ViewBuilder
    private var frozenTombstone: some View {
        let frozen = backlogService.frozen
        if !frozen.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: DS.Spacing.xs) {
                    Button {
                        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                            showFrozen.toggle()
                        }
                    } label: {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: showFrozen ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .contentTransition(.symbolEffect(.replace))
                            Image(systemName: "snowflake")
                                .font(.caption2)
                            Text("\(frozen.count) frozen")
                                .font(.caption2.monospacedDigit())
                                .contentTransition(.numericText())
                            Spacer()
                        }
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(frozen.count) frozen tasks")

                    Button("Unfreeze all") {
                        // Snapshot IDs so undo knows which ones to re-freeze.
                        let restoredIds = frozen.map(\.id)
                        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                            backlogService.unfreezeAll()
                        }
                        onUndoableAction?("Unfroze \(restoredIds.count) task\(restoredIds.count == 1 ? "" : "s")") { [backlogService] in
                            for id in restoredIds { backlogService.freezeTask(id: id) }
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(skin.accentColor)
                }
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xs)

                if showFrozen {
                    ForEach(frozen) { task in
                        frozenRow(task)
                            .transition(.opacity)
                    }
                }
            }
            .motionAwareAnimation(DS.Animation.standard, value: showFrozen, reduceMotion: reduceMotion)
            .motionAwareAnimation(DS.Animation.quick, value: frozen.map(\.id), reduceMotion: reduceMotion)
        }
    }

    /// One frozen-task row. Snowflake checkbox; tapping it unfreezes.
    @ViewBuilder
    private func frozenRow(_ task: BacklogTask) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Color.clear
                .frame(width: DS.Size.iconLarge, height: DS.Size.accentBarHeight)

            Button {
                let snapshot = task
                withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                    backlogService.unfreezeTask(id: task.id)
                }
                onUndoableAction?("Unfroze \u{201C}\(task.title)\u{201D}") { [backlogService] in
                    backlogService.updateTask(snapshot)
                    backlogService.freezeTask(id: snapshot.id)
                }
            } label: {
                Image(systemName: "snowflake")
                    .font(.callout)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Unfreeze task")
            .accessibilityLabel("Unfreeze \u{201C}\(task.title)\u{201D}")

            Text(task.title)
                .font(.callout)
                .foregroundStyle(skin.resolvedTextTertiary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.xs)
        .frame(minHeight: Self.compactRowHeight)
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

    /// Build a typed drag payload for `task` so drag sources and drop targets
    /// share the same snapshot. Keeps the service out of the drop hot path.
    private func payload(for task: BacklogTask) -> BacklogTaskDrag {
        BacklogTaskDrag(
            taskId: task.id,
            title: task.title,
            durationMinutes: task.durationMinutes,
            context: task.context
        )
    }

    // MARK: - Reorder handling

    /// A task was dropped onto another task — reorder so the dragged one lands
    /// immediately before the target. If the two tasks live in different
    /// context groups, the dragged task also adopts the target's context so
    /// the visual drop matches where the user aimed; otherwise the drag
    /// would appear to do nothing (grouping would undo the move).
    private func handleReorderDrop(dropped: BacklogTaskDrag, targetId: String) {
        guard dropped.taskId != targetId,
              let originalTask = backlogService.tasks.first(where: { $0.id == dropped.taskId }),
              backlogService.tasks.contains(where: { $0.id == targetId }),
              let target = backlogService.tasks.first(where: { $0.id == targetId })
        else { return }

        // Snapshot for undo — index, context, and the ID of the task that
        // used to follow this one (so we can restore exact adjacency).
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
        hasDragged = true
        coordinator?.endDrag()

        // Undo: restore index + context in one step.
        let taskId = originalTask.id
        let originalSnapshot = originalTask
        onUndoableAction?(
            contextChanged
                ? "Moved \u{201C}\(originalTask.title)\u{201D} to \(target.context ?? "No project")"
                : "Reordered \u{201C}\(originalTask.title)\u{201D}"
        ) { [backlogService] in
            guard var current = backlogService.tasks.first(where: { $0.id == taskId }) else {
                // Task was deleted during the toast window — best effort restore
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

    /// Move a task up or down by one slot (keyboard / context menu action).
    private func moveTask(_ task: BacklogTask, by delta: Int) {
        let ordered = activeTasks
        guard let current = ordered.firstIndex(where: { $0.id == task.id }) else { return }
        let target = current + delta
        guard ordered.indices.contains(target) else { return }
        let targetId = ordered[target].id

        let previousIndex = backlogService.indexOfTask(id: task.id)
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            if delta < 0 {
                backlogService.moveTask(id: task.id, before: targetId)
            } else {
                // Move "after" = move before the item *after* the target,
                // or to the end if the target is already last.
                if target + 1 < ordered.count {
                    backlogService.moveTask(id: task.id, before: ordered[target + 1].id)
                } else {
                    backlogService.moveTaskToEnd(id: task.id)
                }
            }
        }
        // The user has discovered reorder — via keyboard, not drag, but the
        // discoverability hint's job is done either way. Birman: don't keep
        // selling a feature the user already uses.
        if !hasDragged { hasDragged = true }

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
                if let firstActive = activeTasks.first, firstActive.id != task.id {
                    backlogService.moveTask(id: task.id, before: firstActive.id)
                }
            } else {
                backlogService.moveTaskToEnd(id: task.id)
            }
        }
        if !hasDragged { hasDragged = true }
        let taskId = task.id
        onUndoableAction?("Moved \u{201C}\(task.title)\u{201D} to \(toTop ? "top" : "bottom")") { [backlogService] in
            guard let previousIndex,
                  let current = backlogService.tasks.first(where: { $0.id == taskId })
            else { return }
            _ = backlogService.removeTask(id: taskId)
            backlogService.restoreTask(current, at: previousIndex)
        }
    }

    private func canMoveUp(_ task: BacklogTask) -> Bool {
        activeTasks.first?.id != task.id && activeTasks.contains(where: { $0.id == task.id })
    }

    private func canMoveDown(_ task: BacklogTask) -> Bool {
        activeTasks.last?.id != task.id && activeTasks.contains(where: { $0.id == task.id })
    }

    private func isUrgent(_ task: BacklogTask) -> Bool {
        guard let deadline = task.deadline else { return false }
        return deadline <= Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date()
    }

    /// Move keyboard focus between active-task rows by `delta` positions.
    /// Boundaries clamp silently — no wrap-around, no audible warning.
    private func focusRow(offsetFrom currentId: String, by delta: Int) {
        let tasks = activeTasks
        guard let idx = tasks.firstIndex(where: { $0.id == currentId }) else { return }
        let target = idx + delta
        guard target >= 0, target < tasks.count else { return }
        focusedTaskId = tasks[target].id
    }

    // MARK: - Complete (undoable)

    /// Complete a task and surface an undo toast.
    ///
    /// HIG / Birman: undo instead of confirmation. The user can always
    /// change their mind within the toast window — `uncomplete` restores
    /// the original `status` + clears `completedAt`.
    private func completeTaskWithUndo(_ task: BacklogTask) {
        // Snapshot the full task BEFORE completing so the undo restores the
        // exact state (including any prior `.scheduled` status, not just a
        // blanket `.pending`).
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.entrance, reduceMotion: reduceMotion)) {
            backlogService.completeTask(id: task.id)
        }
        onUndoableAction?("Completed \u{201C}\(task.title)\u{201D}") { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    // MARK: - Hover slot preview

    /// Debounce constant for per-row slot lookups. Matches the 300 ms used
    /// by the ghost preview under the "Add task" field so the two signals
    /// feel like the same feature.
    private static let slotPreviewHoverDebounceMs: Int = 250

    /// Cheap fingerprint covering the fields that affect "where would this
    /// land?" answers — any change invalidates all cached previews. Includes
    /// total duration, task count, and calendar event count so edits,
    /// additions, deletions and calendar mutations all trip the refresh.
    private var taskHoverCacheFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(activeTasks.count)
        hasher.combine(activeTasks.reduce(0) { $0 + $1.durationMinutes })
        hasher.combine(reminderService.allEvents.count)
        return hasher.finalize()
    }

    /// Kick off (or cancel) the slot lookup for a row the cursor entered or
    /// left. Results land in `rowSlotPreviews` so SwiftUI re-renders the
    /// inline "→ Today 15:00" hint. A cached answer short-circuits the
    /// compute — calendar state rarely shifts enough during a single hover
    /// session to make a re-lookup worth the cost.
    private func handleRowHover(task: BacklogTask, hovering: Bool) {
        let taskId = task.id

        // Cursor left the row — cancel any pending lookup but keep the cache
        // so a quick return flashes the preview without spinning again.
        guard hovering else {
            rowSlotPreviewTasks[taskId]?.cancel()
            rowSlotPreviewTasks[taskId] = nil
            return
        }

        // Already cached → nothing to do; the row reads `rowSlotPreviews`
        // directly via `slotPreview`.
        if rowSlotPreviews[taskId] != nil { return }
        if rowSlotPreviewTasks[taskId] != nil { return }

        let duration = task.durationMinutes
        rowSlotPreviewTasks[taskId] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.slotPreviewHoverDebounceMs))
            guard !Task.isCancelled else { return }

            let slot = FreeSlotFinder.nextSlot(
                matching: duration,
                in: reminderService.allEvents,
                workingHours: optimizerService.workingHours,
                maxDaysAhead: 7
            )
            guard !Task.isCancelled else { return }

            if let slot {
                let fmt = DateFormatter()
                fmt.setLocalizedDateFormatFromTemplate("H:mm")
                let range = "\(fmt.string(from: slot.start))–\(fmt.string(from: slot.end))"
                rowSlotPreviews[taskId] = "\(Self.dayLabel(for: slot.start)) \(range)"
            } else {
                rowSlotPreviews[taskId] = "no free slot this week"
            }
            rowSlotPreviewTasks[taskId] = nil
        }
    }

    /// Cancel every in-flight hover lookup. Called from `.onDisappear` so
    /// Task closures don't outlive the view.
    private func cancelAllRowSlotPreviews() {
        for (_, task) in rowSlotPreviewTasks { task.cancel() }
        rowSlotPreviewTasks.removeAll()
    }

    /// Freeze a task and surface an undo toast. Mirrors
    /// `completeTaskWithUndo` — snapshot first so the undo restores any
    /// prior scheduled state, not just `.pending`.
    private func freezeTaskWithUndo(_ task: BacklogTask) {
        let snapshot = task
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.freezeTask(id: task.id)
        }
        onUndoableAction?("Froze \u{201C}\(task.title)\u{201D}") { [backlogService] in
            backlogService.updateTask(snapshot)
        }
    }

    // MARK: - Add Task Field

    private var addTaskField: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(isInputFocused ? AnyShapeStyle(skin.accentColor) : AnyShapeStyle(.tertiary))

                // Birman: placeholder — возможность научить синтаксису, а не
                // просто пустое «Add task…». На фокусе остаётся краткий
                // «Add task…» — пример уже показан chip-подсказкой выше.
                TextField(addTaskPlaceholder, text: $newTaskTitle)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($isInputFocused)
                    .onSubmit { addTask() }
                    .onExitCommand {
                        // HIG: Escape cancels out of the field. Clears any
                        // draft + ghost so the next ⌘K / tab lands on a
                        // clean slate.
                        newTaskTitle = ""
                        isInputFocused = false
                    }
                    .onChange(of: newTaskTitle) {
                        computeGhostPreview()
                    }

                // Parsed-duration chip — появляется в тот момент, когда
                // парсер распознаёт «30m», «1h30m» и т.п. Пользователь
                // видит, что понято, до того как нажмёт Return.
                if let minutes = recognizedDurationMinutes {
                    Text(DS.formatMinutes(minutes))
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(skin.accentColor)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xxs)
                        .background(
                            Capsule().fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .accessibilityLabel("Parsed duration: \(DS.formatMinutes(minutes))")
                }
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                    .fill(skin.accentColor.opacity(isInputFocused ? DS.Opacity.lightFill : DS.Opacity.subtleFill))
            )
            .motionAwareAnimation(DS.Animation.quick, value: recognizedDurationMinutes, reduceMotion: reduceMotion)

            // Hint for new users — disappears once they add a task.
            if activeTasks.isEmpty && !isInputFocused {
                Text("Tasks you add here will be scheduled into free slots")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .transition(.opacity)
            }

            // Focused-state shortcut hint. HIG: discoverable shortcuts —
            // surface the two keys that matter (submit + cancel) exactly
            // while the field is active, then get out of the way. Birman:
            // подсказка живёт в том же месте, что и поле, без отдельной
            // «панели помощи».
            if isInputFocused {
                HStack(spacing: DS.Spacing.xs) {
                    Text("\u{23CE} Add")
                    Text("·").foregroundStyle(skin.resolvedTextTertiary.opacity(DS.Opacity.half))
                    Text("\u{238B} Cancel")
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextTertiary)
                .transition(.opacity)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.sm)
        .motionAwareAnimation(DS.Animation.quick, value: isInputFocused, reduceMotion: reduceMotion)
    }

    /// TextField placeholder. Teaching syntax when the backlog is empty
    /// («try: Write report 30m»), compact «Add task…» otherwise.
    private var addTaskPlaceholder: String {
        activeTasks.isEmpty
            ? "Add task — try: Write report 30m"
            : "Add task\u{2026}"
    }

    // MARK: - Ghost Preview

    /// Text hint under the input ("Today 14:00–15:00"). Kept in addition to
    /// the timeline ghost block so VoiceOver users, compact layouts, and the
    /// `no free slot this week` fallback still have a visible signal.
    @ViewBuilder
    private var ghostPreviewRow: some View {
        if let preview = ghostPreviewText, !newTaskTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            // Birman: если объект выглядит как кнопка — он должен быть
            // кнопкой. Раньше предпросмотр слота был пассивным текстом, и
            // мышиные пользователи всё равно тянулись к Return. Теперь это
            // явный CTA: клик = добавить задачу (тот же путь, что Return).
            // Знак «↩» подсказывает клавиатурный эквивалент без отдельной
            // подписи.
            let isNoSlot = preview == "no free slot this week"
            Button {
                if !isNoSlot { addTask() }
            } label: {
                HStack(spacing: DS.Spacing.xxs) {
                    Text(preview)
                        // Бump to .caption + medium weight so the main
                        // feedback to typing isn't mistaken for a footnote.
                        // no-slot case stays quiet (it's info, not a CTA).
                        .font(isNoSlot ? .caption2 : .caption.weight(.medium))
                    if !isNoSlot {
                        Text("\u{23CE}")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(skin.accentColor)
                    }
                }
                .foregroundStyle(
                    isNoSlot
                        ? skin.resolvedTextTertiary
                        : skin.accentColor
                )
                .lineLimit(1)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .background {
                    // Subtle capsule reinforces «это кнопка» — only for the
                    // actionable variant; no-slot text stays unboxed.
                    if !isNoSlot {
                        Capsule().fill(skin.accentColor.opacity(DS.Opacity.lightFill))
                    }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isNoSlot)
            .help(isNoSlot ? preview : "Schedule at \(preview)")
            .transition(.opacity.combined(with: .move(edge: .top)))
            .motionAwareAnimation(DS.Animation.standard, value: preview, reduceMotion: reduceMotion)
            .accessibilityLabel(isNoSlot ? preview : "Schedule at \(preview)")
            .accessibilityHint(Text("The new task would land at \(preview)."))
        }
    }

    private func computeGhostPreview() {
        ghostPreviewTask?.cancel()
        let parsed = BacklogTitleParser.parse(newTaskTitle)
        guard !parsed.cleaned.isEmpty else {
            ghostPreviewText = nil
            coordinator?.clearGhost()
            return
        }

        let duration = parsed.durationMinutes ?? Self.defaultTaskDurationMinutes
        let previewTitle = parsed.cleaned

        ghostPreviewTask = Task { @MainActor in
            // Debounce: wait 300 ms after last keystroke so we don't thrash
            // the slot finder for every character.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            // Share one shared finder with FreeSlotRow so the row the user
            // will see and the ghost preview always agree.
            let slot = FreeSlotFinder.nextSlot(
                matching: duration,
                in: reminderService.allEvents,
                workingHours: optimizerService.workingHours,
                maxDaysAhead: 7
            )
            guard !Task.isCancelled else { return }

            if let slot {
                let fmt = DateFormatter()
                fmt.setLocalizedDateFormatFromTemplate("H:mm")
                let range = "\(fmt.string(from: slot.start))–\(fmt.string(from: slot.end))"
                ghostPreviewText = "\(Self.dayLabel(for: slot.start)) \(range)"
                coordinator?.setGhost(slot: slot, title: previewTitle)
            } else {
                ghostPreviewText = "no free slot this week"
                coordinator?.clearGhost()
            }
        }
    }

    /// Localised label describing how far off `date` is from today.
    /// Used by the ghost preview — keep it short so it fits on one line.
    static func dayLabel(for date: Date, calendar cal: Calendar = .current) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("EEE")
        return fmt.string(from: date)
    }

    private func addTask() {
        let parsed = BacklogTitleParser.parse(newTaskTitle)
        let title = parsed.cleaned
        guard !title.isEmpty else { return }

        let task = BacklogTask(
            title: title,
            durationMinutes: parsed.durationMinutes ?? Self.defaultTaskDurationMinutes,
            priority: .medium
        )
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.addTask(task)
            if expansion == .collapsed {
                expansion = .compact
            }
        }
        newTaskTitle = ""
        ghostPreviewText = nil
        ghostPreviewTask?.cancel()
        coordinator?.clearGhost()
    }
}

// MARK: - Capacity Ring

/// Small ring that compares today's remaining working minutes against the
/// total duration still in the backlog. One visual channel — colour —
/// carries the answer: green = fits, orange = tight (≤ 120%),
/// red = overflow. Empty backlog = full green ring (nothing at risk).
///
/// Birman: одно кольцо даёт больше, чем таблица цифр.
struct BacklogCapacityRing: View {
    let pendingMinutes: Int
    let remainingWorkdayMinutes: Int

    @Environment(\.activeSkin) private var skin

    /// Ratio of workload to available time. Guards against division-by-zero
    /// when the workday is over (remaining = 0): in that case, any workload
    /// is overflow; an empty backlog still reads as "fine" (returns 0).
    private var fraction: Double {
        guard pendingMinutes > 0 else { return 0 }
        guard remainingWorkdayMinutes > 0 else { return 1.5 } // overflow sentinel
        return Double(pendingMinutes) / Double(remainingWorkdayMinutes)
    }

    private var color: Color {
        switch fraction {
        case ..<0.8: return .green
        case ..<1.0: return skin.accentColor
        case ..<1.2: return .orange
        default:     return skin.resolvedDestructiveColor
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(skin.resolvedTextTertiary.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0.05), 1.0))
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        .accessibilityLabel("Backlog capacity")
        .accessibilityValue("\(Int(fraction * 100)) percent of remaining workday")
    }
}

// MARK: - Backlog Task Row

struct BacklogTaskRow: View {
    let task: BacklogTask
    let isUrgent: Bool
    /// True while this specific row is being dragged by the user. Used to dim
    /// the source row so it's clear what's in flight.
    var isDragging: Bool = false
    /// Whether keyboard/context-menu reorder is currently possible. Disables
    /// the menu entries cleanly on the first and last rows.
    var canMoveUp: Bool = true
    var canMoveDown: Bool = true
    /// Sprint mode tints the row for calmer reading: metadata/controls
    /// disappear, the title takes a larger font. See `BacklogView.isSprintMode`.
    var isSprintMode: Bool = false
    var onComplete: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    /// Fired when the user picks "Freeze" from the context menu. Optional so
    /// preview call-sites that don't care about freezing can omit it.
    var onFreeze: () -> Void = {}
    /// Fired when this row enters the drag state so the parent can push the
    /// typed payload onto the shared coordinator.
    var onDragStart: () -> Void = {}
    /// Fired when the drag session ends (regardless of whether a drop landed).
    var onDragEnd: () -> Void = {}
    /// Fired when another backlog task is dropped onto this row. The parent
    /// decides how to integrate the drop (reorder and/or context swap).
    var onReorderDrop: (BacklogTaskDrag) -> Void = { _ in }
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onMoveToTop: () -> Void = {}
    var onMoveToBottom: () -> Void = {}
    /// True when this row owns keyboard focus — drives the focus ring visual.
    var isFocused: Bool = false
    /// Move focus to the previous / next visible row. Called on plain ↑ / ↓
    /// (without Cmd) so keyboard navigation feels like List without the
    /// constraints of wrapping the backlog in a real List.
    var onFocusPrev: () -> Void = {}
    var onFocusNext: () -> Void = {}
    /// Pre-computed "when this would land" preview, shown inline on hover.
    /// The parent computes it the first time the cursor enters this row and
    /// caches the result. nil = not computed yet / no slot found.
    var slotPreview: String? = nil
    /// Side-channel hover notification — the parent uses it to trigger the
    /// slot-preview lookup. Mirrors the internal `isHovered` state but lets
    /// the owning view debounce the work without polluting row state.
    var onHoverChanged: (Bool) -> Void = { _ in }

    @State private var isHovered = false
    @State private var isReorderTargeted = false
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Metadata rendered as a single `Text` with middot separators so the
    /// whole chain truncates as one unit (`.lineLimit(1)` on the wrapping
    /// view). Per-segment `foregroundStyle` survives concatenation.
    ///
    /// Birman: один типографический голос для метаданных; срочный дедлайн
    /// получает красный акцент как единственная семантическая подсветка.
    /// Single primary metric for the collapsed row.
    ///
    /// Birman: "one piece of information, not a salad." The deadline wins
    /// whenever it's set — it's the most actionable answer to "should I do
    /// this now?" — and gets the urgency colour (red today/overdue,
    /// standard secondary otherwise). Without a deadline, duration fills
    /// in; it's always useful for "does this fit in my next slot?"
    ///
    /// Story points, context, and other detail move to the hover-reveal
    /// below (`secondaryMetaText`) and to the edit card. The title already
    /// carries deadline urgency via the colour beacon, so this line doesn't
    /// need to repeat "today / tomorrow" colour-wise — its role is to give
    /// the *label* the beacon can't (e.g. "in 3 days").
    private var metaText: Text {
        if let deadline = task.deadline {
            let color: Color = isUrgent
                ? skin.resolvedDestructiveColor
                : skin.resolvedTextSecondary
            return Text(deadlineLabel(deadline))
                .foregroundStyle(color)
        }
        return Text(DS.formatMinutes(task.durationMinutes))
            .foregroundStyle(skin.resolvedTextSecondary)
    }

    /// Everything that was pushed off the primary line — duration (when
    /// deadline is primary), story points, project context. Revealed only
    /// on hover so the collapsed row stays one clean statement. The hover
    /// slot preview sits on the opposite end of the row, so the two never
    /// fight for space.
    private var secondaryMetaText: Text? {
        let dot = Text("\u{00A0}·\u{00A0}").foregroundStyle(skin.resolvedTextTertiary)
        var parts: [Text] = []

        // Duration is redundant when the primary line is already showing it.
        if task.deadline != nil {
            parts.append(
                Text(DS.formatMinutes(task.durationMinutes))
                    .foregroundStyle(skin.resolvedTextTertiary)
            )
        }

        if let sp = task.storyPoints {
            parts.append(
                Text("\(sp)\u{00A0}sp")
                    .foregroundStyle(skin.resolvedTextTertiary)
            )
        }

        if let context = task.context {
            parts.append(
                Text(context)
                    .foregroundStyle(skin.resolvedTextTertiary)
            )
        }

        guard !parts.isEmpty else { return nil }
        return parts.dropFirst().reduce(parts[0]) { acc, next in
            acc + dot + next
        }
    }

    /// Full VoiceOver label for the content button — assembles title,
    /// duration, priority, deadline and project in one sentence so the
    /// row is announced meaningfully.
    private var accessibilityRowLabel: String {
        var parts: [String] = [task.title, DS.formatMinutes(task.durationMinutes)]
        if task.priority == .high { parts.append("high priority") }
        if let sp = task.storyPoints { parts.append("\(sp) story points") }
        if let deadline = task.deadline {
            parts.append("due \(deadlineLabel(deadline))")
        }
        if let context = task.context { parts.append("in \(context)") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            // Drag handle and trailing controls vanish in sprint mode so the
            // row reads as a quiet single column — «один режим, одна цель».
            if !isSprintMode {
                dragHandle
            }
            checkbox
            content
            Spacer(minLength: DS.Spacing.xs)
            if !isSprintMode {
                controls
            }
        }
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.xs)
        .frame(minHeight: isSprintMode ? BacklogView.compactRowHeight + 8 : BacklogView.compactRowHeight)
        .contentShape(Rectangle())
        .opacity(isDragging ? DS.Opacity.tertiaryText : 1)
        .background(rowBackground)
        .overlay(alignment: .top) { dropBar }
        .overlay { focusRing }
        .onHover { hovering in
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                isHovered = hovering
            }
            onHoverChanged(hovering)
        }
        .dropDestination(for: BacklogTaskDrag.self) { items, _ in
            guard let dropped = items.first, dropped.taskId != task.id else { return false }
            onReorderDrop(dropped)
            return true
        } isTargeted: { targeted in
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                isReorderTargeted = targeted
            }
        }
        .contextMenu {
            Button("Complete") { onComplete() }
            Button("Edit") { onEdit() }
            Divider()
            Button("Move Up") { onMoveUp() }
                .disabled(!canMoveUp)
            Button("Move Down") { onMoveDown() }
                .disabled(!canMoveDown)
            Button("Move to Top") { onMoveToTop() }
                .disabled(!canMoveUp)
            Button("Move to Bottom") { onMoveToBottom() }
                .disabled(!canMoveDown)
            Divider()
            // Freeze — non-destructive "set aside". Offered before Delete so
            // the destructive action isn't the default path for tasks the
            // user just doesn't want to plan right now.
            Button("Freeze") { onFreeze() }
            Button("Delete", role: .destructive) { onDelete() }
        }
        .accessibilityAction(named: "Move Up") { onMoveUp() }
        .accessibilityAction(named: "Move Down") { onMoveDown() }
        // Keyboard navigation on the focused row. HIG: full keyboard access.
        // Плоский arrow (без Cmd) перемещает фокус между строками, Cmd-arrow
        // — переставляет сами строки. Space / Return / Delete — основные
        // глаголы (complete / edit / delete).
        .onKeyPress(keys: [.space, .return, .upArrow, .downArrow, .delete]) { press in
            switch press.key {
            case .space:
                onComplete()
                return .handled
            case .return:
                onEdit()
                return .handled
            case .delete:
                // ⌘⌫ = freeze (non-destructive set-aside); plain ⌫ = delete.
                // Mirrors the context-menu ordering: Freeze precedes Delete,
                // so the safer verb gets the modifier shortcut.
                if press.modifiers.contains(.command) {
                    onFreeze()
                } else {
                    onDelete()
                }
                return .handled
            case .upArrow:
                if press.modifiers.contains(.command) {
                    if canMoveUp { onMoveUp() }
                } else {
                    onFocusPrev()
                }
                return .handled
            case .downArrow:
                if press.modifiers.contains(.command) {
                    if canMoveDown { onMoveDown() }
                } else {
                    onFocusNext()
                }
                return .handled
            default:
                return .ignored
            }
        }
    }

    // MARK: - Row sub-views

    /// Drag handle — the ONLY drag source on this row.
    ///
    /// Uses .onDrag (NSItemProvider API) instead of .draggable
    /// (Transferable API). On macOS, .draggable() fails to start
    /// NSDrag sessions inside popover windows and when competing
    /// with child gestures. .onDrag uses NSItemProvider directly,
    /// bypassing the Transferable encoding path that silently
    /// breaks in these contexts.
    ///
    /// Birman: hover-only — affordance, который вечно светится, становится
    /// шумом. Курсор и так подскажет grab при наведении; онбординг живёт
    /// на самой цели — в `FreeSlotRow` через `canShowDragHint`.
    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption2)
            .foregroundStyle(skin.resolvedTextTertiary)
            .frame(width: DS.Size.iconLarge, height: DS.Size.accentBarHeight)
            .contentShape(Rectangle())
            .opacity(isHovered ? 1 : 0)
            .accessibilityHidden(true)
            .onDrag {
                onDragStart()
                let payload = BacklogTaskDrag(
                    taskId: task.id,
                    title: task.title,
                    durationMinutes: task.durationMinutes,
                    context: task.context
                )
                let provider = NSItemProvider()
                if let data = try? JSONEncoder().encode(payload) {
                    provider.registerDataRepresentation(
                        forTypeIdentifier: UTType.json.identifier,
                        visibility: .ownProcess
                    ) { completion in
                        completion(data, nil)
                        return nil
                    }
                }
                return provider
            } preview: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.caption)
                    Text(task.title)
                        .font(.caption.weight(.medium))
                    Text(DS.formatMinutes(task.durationMinutes))
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xs)
                .background(skin.resolvedButtonMaterial, in: Capsule())
                .onDisappear { onDragEnd() }
            }
    }

    /// Checkbox — complete on tap.
    /// HIG: controls should be at least 24pt on a side; the ~17pt glyph
    /// gets wrapped in a 24pt hit-area so the tap target is forgiving.
    private var checkbox: some View {
        Button(action: onComplete) {
            Image(systemName: "circle")
                .font(.callout)
                .foregroundStyle(isUrgent ? skin.resolvedDestructiveColor : skin.resolvedTextSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Mark complete")
        .accessibilityLabel("Mark \u{201C}\(task.title)\u{201D} complete")
    }

    /// Single-line content: title + priority dot + middot-separated metadata.
    /// Title gets `layoutPriority(1)` so it holds onto space; metadata
    /// truncates first when the row narrows.
    ///
    /// Birman: точка приоритета — пометка на полях, после заголовка, чтобы
    /// первое касание взгляда получал смысл, а не маркер.
    /// Deadline colour beacons: the title itself tinted red for today, orange
    /// for tomorrow. A reader scanning the list catches "due now" without
    /// parsing any icon — colour carries the meaning.
    private var content: some View {
        Button(action: onEdit) {
            HStack(spacing: DS.Spacing.xs) {
                // Title wraps to two lines instead of ellipsising.
                // Birman: «…» прячет ровно ту информацию, по которой
                // принимается решение. Row height is `minHeight`, so
                // short titles still sit in 40pt; long ones breathe.
                // Tooltip backstop for cases where wrap still truncates.
                Text(task.title)
                    .font(isSprintMode ? .headline.weight(.medium) : .callout)
                    .foregroundStyle(titleColor)
                    .lineLimit(isSprintMode ? 1 : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .help(task.title)

                // Recurring marker. If the task carries a `recurrenceTag`
                // ("weekly review", "daily standup"), show it as human text
                // instead of only a cryptic glyph — Бирман: «язык интерфейса —
                // язык человека». The bare ⟲ remains for tag-less recurring
                // tasks so the affordance is still present.
                if task.isRecurring {
                    HStack(spacing: DS.Spacing.xxs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                        if let tag = task.recurrenceTag,
                           !tag.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text(tag)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        (task.recurrenceTag?.isEmpty == false)
                            ? "Recurring: \(task.recurrenceTag!)"
                            : "Recurring"
                    )
                }

                // Dependency marker — mirrors the edit form's "depends on"
                // section. A small arrow hints at the relationship without
                // naming the blockers inline (titles could be long).
                if !task.dependsOn.isEmpty {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .accessibilityLabel("Depends on \(task.dependsOn.count) task\(task.dependsOn.count == 1 ? "" : "s")")
                }

                if task.priority == .high {
                    Circle()
                        .fill(skin.resolvedDestructiveColor)
                        .frame(width: DS.Size.recipeDotSize, height: DS.Size.recipeDotSize)
                        .accessibilityLabel("High priority")
                }

                // One primary metric at rest (deadline if set, else duration).
                // Birman: «одна метрика, а не панель». In sprint mode we drop
                // even that — only the title matters, nothing else is on
                // screen to fight with.
                if !isSprintMode {
                    metaText
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // On hover, surface the richer metadata that was suppressed
                // at rest — duration (when deadline was primary), story
                // points, project context. `secondaryMetaText` already
                // returns nil when there's nothing to add, so the pill
                // simply doesn't appear for bare tasks.
                if isHovered, !isSprintMode, let secondary = secondaryMetaText {
                    secondary
                        .font(.caption2)
                        .lineLimit(1)
                        .transition(.opacity)
                }

                // Hover-only slot preview. Mirrors the ghost preview that
                // appears under the "Add task" field for new tasks — here it
                // answers "where would THIS existing task land if I scheduled
                // now?" without requiring a drag. Hidden during drag so the
                // row doesn't double-up with the ghost block on the timeline.
                if isHovered, !isDragging, let slotPreview, !isSprintMode {
                    Text("→ \(slotPreview)")
                        .font(.caption2)
                        .foregroundStyle(skin.accentColor.opacity(DS.Opacity.accentMuted))
                        .lineLimit(1)
                        .transition(.opacity)
                        .accessibilityLabel("Would land at \(slotPreview)")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityRowLabel)
        .accessibilityHint("Double-tap to edit")
    }

    /// Title colour — red when the deadline is today or overdue, orange for
    /// tomorrow, primary text otherwise. One channel of information, no icon
    /// required. Low-priority tasks with no deadline read as normal text.
    private var titleColor: Color {
        guard let deadline = task.deadline else { return skin.resolvedTextPrimary }
        let cal = Calendar.current
        if deadline < Date() || cal.isDateInToday(deadline) {
            return skin.resolvedDestructiveColor
        }
        if cal.isDateInTomorrow(deadline) {
            return .orange
        }
        return skin.resolvedTextPrimary
    }

    /// Reorder + delete controls, visible only on hover (Apple Reminders /
    /// Things pattern). HIG: reserve the horizontal space so layout doesn't
    /// jump when the cursor enters / leaves.
    private var controls: some View {
        HStack(spacing: DS.Spacing.xxs) {
            Button(action: onMoveUp) {
                Image(systemName: "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(canMoveUp ? skin.resolvedTextSecondary : skin.resolvedTextTertiary.opacity(DS.Opacity.half))
            }
            .buttonStyle(.plain)
            .disabled(!canMoveUp)
            .help("Move up")
            .accessibilityLabel("Move \u{201C}\(task.title)\u{201D} up")

            Button(action: onMoveDown) {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(canMoveDown ? skin.resolvedTextSecondary : skin.resolvedTextTertiary.opacity(DS.Opacity.half))
            }
            .buttonStyle(.plain)
            .disabled(!canMoveDown)
            .help("Move down")
            .accessibilityLabel("Move \u{201C}\(task.title)\u{201D} down")

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .buttonStyle(.plain)
            .help("Delete task")
            .accessibilityLabel("Delete \u{201C}\(task.title)\u{201D}")
        }
        .opacity(isHovered ? 1 : 0)
        // Keep the controls out of the accessibility tree when hidden
        // so VoiceOver doesn't announce ghost buttons.
        .accessibilityHidden(!isHovered)
    }

    /// Row background — drop highlight wins over hover tint when both fire.
    /// HIG: use colour purposefully; the accent fill *means* "drop lands here",
    /// the neutral hover tint *means* "this row is under your cursor".
    private var rowBackground: some View {
        let accent = skin.accentColor.opacity(DS.Opacity.lightFill)
        let hoverTint = skin.resolvedTextTertiary.opacity(0.06)
        let fill: Color = isReorderTargeted
            ? accent
            : (isHovered ? hoverTint : .clear)
        return RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
            .fill(fill)
    }

    /// Thin accent bar at the top edge while a drag is targeted at this row —
    /// makes the drop position unambiguous.
    private var dropBar: some View {
        Rectangle()
            .fill(skin.accentColor)
            .frame(height: isReorderTargeted ? DS.Border.selection : 0)
            .motionAwareAnimation(DS.Animation.quick, value: isReorderTargeted, reduceMotion: reduceMotion)
    }

    /// Keyboard focus ring. Mirrors the system focus ring visually without
    /// the heavyweight default (which also draws a halo around each embedded
    /// button).
    @ViewBuilder
    private var focusRing: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                .strokeBorder(skin.accentColor, lineWidth: 2)
        }
    }

    private func deadlineLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if date < now { return "Overdue" }
        // Birman: язык интерфейса — язык человека. "in 5 days" вместо "5d".
        // `.relative(presentation: .numeric)` локализовано, без ручной сборки.
        return date.formatted(.relative(presentation: .numeric))
    }
}

// MARK: - Backlog Task Edit Row (Inline, Autosave)

/// Truly inline editing — every change persists immediately, no Save/Cancel
/// chrome, Esc collapses the card back to the read-only row.
///
/// HIG: direct manipulation — the form IS the task, not a dialog about the
/// task. ⌘↩ and Esc (and clicking Return in the title) all end editing.
/// Birman: *«редактирование без модальности»* — значит не «сохранить и
/// применить», а «менять — уже применено». Отмена — через undo-toast на
/// Complete / Delete / Reorder, не через Cancel-кнопку.
struct BacklogTaskEditRow: View {
    let task: BacklogTask
    var backlogService: BacklogService
    var onDone: () -> Void

    @State private var title: String
    @State private var durationMinutes: Int
    @State private var priority: TaskPriority
    @State private var deadline: Date?
    @State private var hasDeadline: Bool
    @State private var context: String
    @State private var storyPoints: Int?
    @State private var isRecurring: Bool
    @State private var recurrenceTag: String
    @State private var dependsOn: [String]
    /// Currently-selected task in the "Add dependency" picker — resets to nil
    /// after each successful add so the picker returns to its placeholder.
    @State private var newDependencyId: String? = nil
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isTitleFocused: Bool

    init(task: BacklogTask, backlogService: BacklogService, onDone: @escaping () -> Void) {
        self.task = task
        self.backlogService = backlogService
        self.onDone = onDone
        _title = State(initialValue: task.title)
        _durationMinutes = State(initialValue: task.durationMinutes)
        _priority = State(initialValue: task.priority)
        _deadline = State(initialValue: task.deadline)
        _hasDeadline = State(initialValue: task.deadline != nil)
        _context = State(initialValue: task.context ?? "")
        _storyPoints = State(initialValue: task.storyPoints)
        _isRecurring = State(initialValue: task.isRecurring)
        _recurrenceTag = State(initialValue: task.recurrenceTag ?? "")
        _dependsOn = State(initialValue: task.dependsOn)
    }

    private static let durationOptions = [15, 30, 45, 60, 90, 120, 180, 240]
    private static let spOptions: [Int?] = [nil, 1, 2, 3, 5, 8, 13]
    /// Width of the "Project" inline text field — roughly 15 caption2-chars
    /// at system font; wider than that wastes horizontal space in a
    /// 360pt-wide popover.
    private static let contextFieldWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Title. HIG: Return submits → ends editing; ⌘↩ and Esc do the
            // same. Typography matches the display-state row (.callout, no
            // weight bump) so entering edit mode doesn't feel like a jump.
            TextField("Task name", text: $title)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isTitleFocused)
                .onSubmit { commit() }
                .onChange(of: title) { _, _ in autosave() }

            // Duration pills
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("Duration")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(Self.durationOptions, id: \.self) { mins in
                            chipButton(
                                label: DS.formatMinutes(mins),
                                isActive: durationMinutes == mins
                            ) {
                                durationMinutes = mins
                                autosave()
                            }
                        }
                    }
                }
            }

            // Priority pills
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("Priority")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextSecondary)
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(TaskPriority.allCases, id: \.self) { p in
                        chipButton(label: p.label, isActive: priority == p) {
                            priority = p
                            autosave()
                        }
                    }
                }
            }

            // Story points
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("Story points")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextSecondary)
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(Self.spOptions, id: \.self) { sp in
                        chipButton(
                            label: sp.map { "\($0)" } ?? "—",
                            isActive: storyPoints == sp
                        ) {
                            storyPoints = sp
                            autosave()
                        }
                    }
                }
            }

            // Deadline toggle + picker
            HStack {
                Toggle("Deadline", isOn: $hasDeadline)
                    .font(.caption2)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: hasDeadline) { _, _ in autosave() }
                if hasDeadline {
                    DatePicker("", selection: Binding(
                        get: { deadline ?? Date() },
                        set: { deadline = $0; autosave() }
                    ), displayedComponents: .date)
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            // Context
            HStack(spacing: DS.Spacing.xs) {
                Text("Project")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextSecondary)
                TextField("optional", text: $context)
                    .textFieldStyle(.plain)
                    .font(.caption2)
                    .frame(maxWidth: Self.contextFieldWidth)
                    .onChange(of: context) { _, _ in autosave() }
                    .onSubmit { commit() }
            }

            // Recurring toggle. Flipped on, completion will reset the task
            // to pending instead of marking it done — useful for weekly
            // reviews, daily standups, etc. A free-form tag becomes the
            // human label shown next to the ⟲ glyph on the row
            // («⟲ weekly review») — Бирман: «язык интерфейса — язык
            // человека», глиф без подписи ничего не говорит.
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack {
                    Toggle("Repeats", isOn: $isRecurring)
                        .font(.caption2)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .onChange(of: isRecurring) { _, _ in autosave() }
                }
                if isRecurring {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedTextTertiary)
                        TextField("e.g. weekly review, daily standup", text: $recurrenceTag)
                            .textFieldStyle(.plain)
                            .font(.caption2)
                            .onChange(of: recurrenceTag) { _, _ in autosave() }
                            .onSubmit { commit() }
                    }
                    .padding(.leading, DS.Spacing.sm)
                    .transition(.opacity)
                }
            }
            .motionAwareAnimation(DS.Animation.quick, value: isRecurring, reduceMotion: reduceMotion)

            // Dependencies. Each entry is another task whose completion
            // should block this one. The picker offers all active tasks
            // except self and already-linked ones; ✕ clears a link.
            dependencySection

            // Footer hint — replaces the old Save/Cancel row. The intent
            // is clear: changes are already saved; user only needs a way
            // to leave edit mode.
            HStack(spacing: DS.Spacing.xs) {
                Spacer()
                Text("\u{23CE} or \u{238B} to finish")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .accessibilityHidden(true)
                Button("Done") { commit() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(skin.accentColor)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Finish editing")
            }
        }
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                .fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
        )
        // HIG: Escape exits the edit state cleanly — previously only a
        // Cancel button handled this, which failed with keyboard-only use.
        .onExitCommand { commit() }
        .task {
            // `.task` instead of `.onAppear` — fires only after the view is
            // in the window hierarchy, which is where FocusState can
            // actually take. Fixes a flaky focus bug where
            // `isTitleFocused = true` in `.onAppear` silently missed.
            try? await Task.sleep(for: .milliseconds(50))
            isTitleFocused = true
        }
    }

    /// Persist the current snapshot without leaving edit mode — fired from
    /// every field's onChange so there's no "unsaved state".
    private func autosave() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        // Don't clobber the title with an empty string — the user is
        // probably mid-edit. Other fields save unconditionally.
        guard !trimmed.isEmpty else { return }
        var updated = task
        updated.title = trimmed
        updated.durationMinutes = durationMinutes
        updated.priority = priority
        updated.deadline = hasDeadline ? (deadline ?? Date()) : nil
        updated.context = context.isEmpty ? nil : context
        updated.storyPoints = storyPoints
        updated.isRecurring = isRecurring
        // Stored as optional so an empty tag round-trips to nil —
        // the row renders the bare ⟲ glyph without an empty label.
        let trimmedTag = recurrenceTag.trimmingCharacters(in: .whitespaces)
        updated.recurrenceTag = (isRecurring && !trimmedTag.isEmpty) ? trimmedTag : nil
        updated.dependsOn = dependsOn
        backlogService.updateTask(updated)
    }

    /// Pick-or-remove UI for task dependencies. Linked tasks render as small
    /// pills with an ✕ button; a trailing picker adds a new link.
    /// Other active tasks from the backlog populate the picker. Frozen/done
    /// tasks are excluded because depending on them means "never unblocks".
    @ViewBuilder
    private var dependencySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text("Depends on")
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextSecondary)

            // Existing dependency pills.
            if !dependsOn.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(dependsOn, id: \.self) { depId in
                            dependencyPill(depId: depId)
                        }
                    }
                }
            }

            // Picker for adding a new dependency. Hidden when there are no
            // candidates so we don't show a dead dropdown.
            let candidates = backlogService.tasks.filter { other in
                other.id != task.id
                    && other.status != .done
                    && other.status != .frozen
                    && !dependsOn.contains(other.id)
            }
            if !candidates.isEmpty {
                Picker("Add dependency", selection: Binding(
                    get: { newDependencyId },
                    set: { selected in
                        if let selected, !dependsOn.contains(selected) {
                            dependsOn.append(selected)
                            autosave()
                        }
                        // Reset selection so the picker returns to the
                        // placeholder row and can be used again.
                        newDependencyId = nil
                    }
                )) {
                    Text("Add dependency\u{2026}").tag(String?.none)
                    ForEach(candidates, id: \.id) { candidate in
                        Text(candidate.title).tag(String?.some(candidate.id))
                    }
                }
                .pickerStyle(.menu)
                .font(.caption2)
                .controlSize(.small)
                .labelsHidden()
            }
        }
    }

    private func dependencyPill(depId: String) -> some View {
        let title = backlogService.tasks.first(where: { $0.id == depId })?.title ?? "Unknown"
        return HStack(spacing: DS.Spacing.xxs) {
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(skin.resolvedTextPrimary)
            Button {
                dependsOn.removeAll { $0 == depId }
                autosave()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove dependency on \u{201C}\(title)\u{201D}")
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xxs)
        .background(
            Capsule().fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
        )
    }

    /// Final save + collapse the edit card back to the read-only row.
    private func commit() {
        autosave()
        onDone()
    }

    private func chipButton(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                // HIG: Contrast depends on the accent colour's luminance —
                // white fails on pastel accents. Compute it per-skin instead
                // of hard-coding .white like we did before.
                .font(.caption2.weight(.medium))
                .foregroundStyle(isActive ? DS.contrastingForeground(for: skin.accentColor) : skin.resolvedTextPrimary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.pillVertical)
                .background(
                    Capsule().fill(isActive ? skin.accentColor : skin.accentColor.opacity(DS.Opacity.lightFill))
                )
        }
        .buttonStyle(.plain)
    }
}
