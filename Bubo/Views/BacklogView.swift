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
    var onScheduleTasks: () -> Void
    var onDeleteTask: ((BacklogTask) -> Void)?
    /// Fired when the user asks to edit a task. The parent owns navigation
    /// state and pushes the editor onto the popover stack — same pattern
    /// as event editing — so the editor opens as a full-screen sibling
    /// surface instead of a detached sheet floating above the list.
    var onEditTask: ((BacklogTask) -> Void)? = nil
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
    /// Cached parse result for `newTaskTitle`. Updated from `onChange` so
    /// the title/duration pair is computed once per keystroke instead of
    /// re-evaluated inside every SwiftUI computed property that reads it
    /// (parsed duration chip, ghost preview, row-count math).
    @State private var parsedNewTaskTitle: (cleaned: String, durationMinutes: Int?) = ("", nil)
    /// Three-state disclosure for the task list.
    /// Birman: «информация важнее украшений» — шеврон сам несёт три смысла
    /// (collapsed / compact / expanded), без дублирующей кнопки «Show more».
    @State private var expansion: TaskListExpansion = .collapsed
    /// Snapshot of `expansion` captured the moment a drag starts. During a
    /// drag the list flips to `.expanded` so the user sees every reorder
    /// target at once, and the pre-drag state is restored when the drag
    /// ends.
    @State private var expansionBeforeDrag: TaskListExpansion? = nil
    /// Measured height of the hosting popover. Drives the dynamic ceiling
    /// for the fully-expanded state so large screens are not forced into a
    /// 480pt cap. Zero until the first layout pass.
    @State private var measuredHostHeight: CGFloat = 0
    /// Hover state for the Schedule pill — HIG: primary actions should read as
    /// buttons, so a subtle capsule фон появляется на наведении.
    @State private var isScheduleHovering: Bool = false
    /// Textual ghost — complements the ghost block on the timeline so
    /// assistive technologies and compact layouts still get "Today 14:00".
    /// The label itself lives in `slotPreviewCache`; `ghostPreviewText`
    /// mirrors the last value rendered under the input so SwiftUI still
    /// animates the row in/out on string change.
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

    /// Shared cache for "where would a task of N minutes land?" lookups.
    /// Both the per-row hover hint and the ghost preview under the input
    /// read from this single source, so they always agree and a calendar
    /// mutation invalidates both signals at once.
    @State private var slotPreviewCache = SlotPreviewCache()

    /// User has already performed at least one drag — used to hide the
    /// onboarding hint once the affordance has been discovered.
    @AppStorage("BuboBacklogHasDragged") private var hasDragged: Bool = false

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

    /// Vertical space we reserve under the list while a backlog task is in
    /// flight. The timeline below collapses to one «N events · Xh booked»
    /// header + 2–3 free slots ≈ 120–140pt — keeping the full 220pt reserve
    /// wastes ~80pt that the task list could use to show more reorder
    /// targets without scrolling.
    private static let dragReservedHeight: CGFloat = 140

    /// Ceiling for the fully-expanded list, derived from the measured host
    /// height so large popovers get a tall list and small hosts stay honest.
    /// While a drag is in flight, the reserve shrinks to `dragReservedHeight`
    /// so Tasks can grow into the space the collapsed timeline no longer
    /// needs. Falls back to `fullyExpandedMaxHeight` before the first
    /// layout pass.
    private var dynamicExpandedMaxHeight: CGFloat {
        guard measuredHostHeight > 0 else { return Self.fullyExpandedMaxHeight }
        let reserve = coordinator?.isDraggingTask == true
            ? Self.dragReservedHeight
            : Self.nonListReservedHeight
        return max(
            Self.fullyExpandedMaxHeight,
            measuredHostHeight - reserve
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
        BacklogLogic.activeTasks(backlogService.tasks)
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

    /// Active tasks as a flat list ordered by `BacklogLogic.smartScore`.
    /// Stable for equal scores: falls back to storage order, so the sorted
    /// list never "shuffles" two tasks the user tied deliberately.
    private var smartSortedActiveTasks: [BacklogTask] {
        BacklogLogic.smartSorted(activeTasks)
    }

    /// Tasks completed since local midnight. Powers the «N completed today»
    /// tombstone — HIG/Birman: сохраняем контекст «сколько сделано сегодня»,
    /// но квартирантом, не жильцом: свёрнуто по умолчанию.
    private var completedToday: [BacklogTask] {
        BacklogLogic.completedToday(backlogService.tasks)
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
    /// created on submit. Reads from `parsedNewTaskTitle`, which is kept
    /// in sync by an `onChange` on the text field.
    private var parsedDurationMinutes: Int {
        parsedNewTaskTitle.durationMinutes ?? optimizerService.defaultTaskDurationMinutes
    }

    /// Same as `parsedDurationMinutes` but returns `nil` when the parser
    /// didn't recognize an explicit duration. Drives the inline chip that
    /// echoes what the parser understood — seeing "30 min" appear confirms
    /// the shorthand was caught before the user commits.
    private var recognizedDurationMinutes: Int? {
        parsedNewTaskTitle.durationMinutes
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
        .onChange(of: focusRequested) { _, requested in
            if requested {
                isInputFocused = true
                focusRequested = false
            }
        }
        // Any backlog edit (duration, context) or event change invalidates
        // the shared preview cache — otherwise a row that was edited 10s ago
        // could keep showing a slot computed against a stale duration. The
        // count + sum is a cheap fingerprint: changes whenever any task
        // grows or shrinks, reschedules, or is added/removed.
        .onChange(of: taskHoverCacheFingerprint) { _, newValue in
            slotPreviewCache.invalidateIfChanged(to: newValue)
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
            slotPreviewCache.cancelAll()
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
                    remainingWorkdayMinutes: remainingWorkdayMinutes,
                    optimizerService: optimizerService
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

    /// Read-only row. Editing pushes a full-screen `EditTaskView` onto the
    /// popover navigation stack via `onEditTask` — same pattern as event
    /// editing — so the row no longer has to swap between a display and
    /// edit representation mid-list, and the editor isn't a detached
    /// modal floating above the list.
    @ViewBuilder
    private func taskRowBody(_ task: BacklogTask) -> some View {
        BacklogTaskRow(
            task: task,
            isUrgent: isUrgent(task),
            isDragging: coordinator?.draggedTask?.taskId == task.id,
            canMoveUp: canMoveUp(task),
            canMoveDown: canMoveDown(task),
            isSprintMode: isSprintMode,
            onComplete: { completeTaskWithUndo(task) },
            onEdit: { onEditTask?(task) },
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
            slotPreview: slotPreviewCache.cached(durationMinutes: task.durationMinutes),
            onHoverChanged: { hovering in
                handleRowHover(task: task, hovering: hovering)
            }
        )
        .focusable()
        .focused($focusedTaskId, equals: task.id)
        .focusEffectDisabled()
        .transition(.opacity.combined(with: .move(edge: .leading)))
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
        BacklogLogic.isUrgent(task)
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

    /// Cheap fingerprint covering the fields that affect "where would this
    /// land?" answers — any change invalidates all cached previews. Includes
    /// total duration, task count, and calendar event count so edits,
    /// additions, deletions and calendar mutations all trip the refresh.
    private var taskHoverCacheFingerprint: Int {
        SlotPreviewCache.fingerprint(
            tasks: activeTasks,
            eventCount: reminderService.allEvents.count
        )
    }

    /// Kick off (or cancel) the slot lookup for a row the cursor entered or
    /// left. The shared `SlotPreviewCache` owns the computation and result
    /// storage — row rendering reads through `slotPreviewCache.cached(...)`.
    private func handleRowHover(task: BacklogTask, hovering: Bool) {
        let duration = task.durationMinutes
        guard hovering else {
            slotPreviewCache.cancel(durationMinutes: duration)
            return
        }
        _ = slotPreviewCache.preview(
            durationMinutes: duration,
            events: reminderService.allEvents,
            workingHours: optimizerService.workingHours
        )
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
                        parsedNewTaskTitle = ("", nil)
                        isInputFocused = false
                    }
                    .onChange(of: newTaskTitle) { _, newValue in
                        parsedNewTaskTitle = BacklogTitleParser.parse(newValue)
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
        let parsed = parsedNewTaskTitle
        guard !parsed.cleaned.isEmpty else {
            ghostPreviewText = nil
            coordinator?.clearGhost()
            return
        }

        let duration = parsed.durationMinutes ?? optimizerService.defaultTaskDurationMinutes
        let previewTitle = parsed.cleaned

        // Share one cache with the per-row hover previews so the row the
        // user will see and the ghost preview always agree. The cache
        // debounces the underlying FreeSlotFinder call (250ms).
        let request = slotPreviewCache.preview(
            durationMinutes: duration,
            events: reminderService.allEvents,
            workingHours: optimizerService.workingHours
        )
        ghostPreviewTask = Task { @MainActor in
            guard let result = await request.value else { return }
            if Task.isCancelled { return }
            ghostPreviewText = result.label
            if let slot = result.slot {
                coordinator?.setGhost(slot: slot, title: previewTitle)
            } else {
                coordinator?.clearGhost()
            }
        }
    }

    /// Localised label describing how far off `date` is from today.
    /// Used by the ghost preview — keep it short so it fits on one line.
    static func dayLabel(for date: Date, calendar cal: Calendar = .current) -> String {
        SlotPreviewCache.dayLabel(for: date, calendar: cal)
    }

    private func addTask() {
        let parsed = parsedNewTaskTitle
        let title = parsed.cleaned
        guard !title.isEmpty else { return }

        let task = BacklogTask(
            title: title,
            durationMinutes: parsed.durationMinutes ?? optimizerService.defaultTaskDurationMinutes,
            priority: .medium
        )
        withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
            backlogService.addTask(task)
            if expansion == .collapsed {
                expansion = .compact
            }
        }
        newTaskTitle = ""
        parsedNewTaskTitle = ("", nil)
        ghostPreviewText = nil
        ghostPreviewTask?.cancel()
        coordinator?.clearGhost()
    }
}

