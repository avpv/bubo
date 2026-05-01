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
    var onDeleteTask: ((BacklogTask) -> Void)?
    /// Fired when the user asks to edit a task. The parent owns navigation
    /// state and pushes the editor onto the popover stack — same pattern
    /// as event editing — so the editor opens as a full-screen sibling
    /// surface instead of a detached sheet floating above the list.
    var onEditTask: ((BacklogTask) -> Void)? = nil
    /// Fired when the user taps the fullscreen-affordance in the Tasks
    /// header. The parent owns navigation state and pushes the fullscreen
    /// Backlog onto the popover stack — same pattern as `onEditTask`.
    var onEnterFullscreen: (() -> Void)? = nil
    /// Fired for any reversible user action (reorder, complete, cross-context
    /// drop) so the parent can surface a unified undo toast — it owns
    /// `ToastState`. nil silently disables the toast; the action still runs.
    ///
    /// HIG: every destructive or hard-to-discover action gets an undo path.
    /// Birman: undo instead of confirmation dialogs.
    var onUndoableAction: ((_ message: String, _ undo: @escaping () -> Void) -> Void)? = nil
    /// Schedule the unscheduled backlog onto the calendar via the optimizer.
    /// Async so the spill-over marker can show a loading spinner inline
    /// during the run. Wired from `MenuBarView.runQuickAction(.scheduleBacklog,…)`.
    var onScheduleBacklog: (() async -> Void)? = nil
    /// Run the deadline-mode preset. Surfaces as the conditional second
    /// action-link in the spill-over marker when overflow contains urgent
    /// tasks. Wired from `MenuBarView.runQuickAction(.deadlineMode,…)`.
    var onFocusOnDeadlines: (() async -> Void)? = nil
    /// Open the command palette seeded with a single task (per-task scope
    /// optimizer entry — context menu's «Reschedule…» on a row).
    var onRescheduleTask: ((BacklogTask) -> Void)? = nil
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
    /// Smart Sort: arranges active tasks by (deadline urgency + priority)
    /// instead of user drag order. Survives per session only — the stored
    /// order remains the user's canonical sequence.
    @State private var useSmartSort: Bool = false
    /// Urgent-only filter: narrows the visible list to tasks whose deadline
    /// falls within `isUrgent`'s window. Toggled by tapping the red «N urgent»
    /// counter in the header — Бирман: «информация, а не украшение».
    /// Session-local only; survives popover close, not app restart.
    @State private var urgentOnlyFilter: Bool = false

    /// ID of the row that was just dropped via drag — set in
    /// `handleReorderDrop`, cleared 0.5 s later via a `Task`. Drives a
    /// brief accent-coloured outline on the row so the user can see
    /// where their dropped task landed (especially when it crossed the
    /// fits → spill-over boundary). Birman: «постоянная мягкая
    /// обратная связь» — `reduceMotion` honoured by the `.animation`
    /// wrapper at the row level.
    @State private var lastDroppedTaskId: String? = nil

    /// Task whose deadline is currently being edited via the inline
    /// `Set deadline…` popover. Set from the row's context-menu callback,
    /// cleared on save / cancel. Hosts the popover anchor — using `.sheet`
    /// would feel heavier than the operation deserves.
    @State private var deadlinePickerTask: BacklogTask? = nil

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
    /// - `.expanded`: internal-only — entered programmatically while a drag
    ///   is in flight so all reorder targets are visible. Не достижимо через
    ///   шеврон; для пользовательского «весь список» теперь служит
    ///   fullscreen Backlog (отдельный аффорданс в header'е).
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
        // Inline deadline picker for the row's «Set deadline…» context-menu
        // item. Anchors on the BacklogView root rather than per-row
        // because SwiftUI's `.contextMenu` + `.popover(item:)` on the same
        // row fight for presentation; a view-level popover is the standard
        // workaround. Save → `updateTask` + undo toast; Cancel discards.
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
    }

    /// Update the task's `deadline` and surface an undo toast — the same
    /// pattern as `toggleUrgent`. Snapshot before mutation so the undo
    /// closure can restore exact state regardless of subsequent edits.
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
            // Birman: вердикт-toast говорит человеку «куда я попал», а не
            // показывает технический timestamp. Today / Tomorrow / weekday
            // / abbreviated date — same vocabulary as the row meta itself.
            let formatted = deadline.formatted(date: .abbreviated, time: .shortened)
            label = "Set deadline on \u{201C}\(task.title)\u{201D} to \(formatted)"
        } else {
            label = "Cleared deadline on \u{201C}\(task.title)\u{201D}"
        }
        onUndoableAction?(label) { [backlogService] in
            backlogService.updateTask(snapshot)
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
            // trailing controls. Birman: кольцо — это _идентификатор_
            // карточки, а не украшение на периферии.
            if totalCount > 0 {
                BacklogCapacityRing(
                    pendingMinutes: pendingWorkloadMinutes,
                    remainingWorkdayMinutes: remainingWorkdayMinutes,
                    optimizerService: optimizerService
                )
                .help(capacityRingTooltip)

                // Verdict next to the ring — «Done by 17:30» / «1h over
                // capacity» / «After hours · 3h queued». Replaces the older
                // «5h / 3h» numbers (which stay reachable through the ring's
                // popover and tooltip) so the inline label is interpretation,
                // not arithmetic the reader has to do themselves.
                BacklogCapacityLabel(
                    pendingMinutes: pendingWorkloadMinutes,
                    overflowingCount: overflowingTaskCount,
                    optimizerService: optimizerService
                )

                // Middot separator between the verdict and the count —
                // turns the run-on «9h over capacity 14 1 urgent» into three
                // visually-separated facts. Birman: middot is the standard
                // Russian/Mac typographic glue between commensurate items;
                // the eye reads each side as its own object.
                headerSeparator
            }

            Button {
                // `.levelChange` for the chevron — collapsed/compact is a
                // discrete card-state change, same magnitude as the
                // urgent / smart-sort toggles below.
                Haptics.impact()
                withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                    expansion = expansion.next
                }
            } label: {
                // Count + plural «task/tasks» word. The previous
                // bare-number layout relied on the capacity verdict to imply
                // «это про задачи», which broke when the verdict was a time
                // («Done by 17:30») and left «14» dangling without a noun.
                // The count now stands on its own as a self-describing fact.
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: expansion.iconName)
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .contentTransition(.symbolEffect(.replace))

                    Text("\(totalCount) task\(totalCount == 1 ? "" : "s")")
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .buttonStyle(.plain)
            .help("\(totalCount) task\(totalCount == 1 ? "" : "s") \u{00B7} \(expansion.accessibilityHint.lowercased())")
            .accessibilityLabel("\(totalCount) tasks")
            .accessibilityHint(expansion.accessibilityHint)

            // Smart-sort indicator — видимое состояние «список не в моём
            // порядке». Раньше тоггл жил только в overflow, и пользователь
            // мог часами пытаться понять, почему задачи переставлены: ON
            // включал, а UI не сигналил. Теперь когда сортировка активна —
            // в header'е появляется аккуратный wand.and.stars; клик на нём
            // выключает обратно. Включать всё ещё через overflow (это редкое
            // действие, не достойно постоянного места в header'е).
            if useSmartSort {
                smartSortIndicator
            }

            // Urgent-count pill — now a real control. Clicking it toggles
            // the urgent-only filter. The leading middot visually frames
            // the pill as a third sibling fact next to the verdict and the
            // count, so the row reads as «verdict · count · urgent» —
            // three separable thoughts instead of one runny line.
            // Birman: «информация — это кнопка», иначе это просто краска.
            if urgentCount > 0 {
                headerSeparator
                urgentFilterButton(urgentCount: urgentCount)
            }

            Spacer()

            if totalCount > 0 {
                // Fullscreen affordance — пушит fullscreen Backlog в
                // навигационный стек popover'а. Раньше эту роль играл
                // третий клик шеврона (`chevron.down.2`), но двойная
                // стрелка не считывалась как «другое состояние». Теперь
                // — отдельная кнопка с понятной macOS-идиомой «развернуть».
                if onEnterFullscreen != nil {
                    fullscreenButton
                }
                // Overflow menu holds smart-sort. HIG: secondary actions
                // without a clear glyph belong in a menu with labels.
                headerOverflowMenu
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.sm)
    }

    /// Tiny accent-coloured wand pill that lights up in the header whenever
    /// smart-sort is engaged. Clicking it disables smart-sort and returns
    /// the list to user drag order. Only rendered when `useSmartSort == true`
    /// — а когда выключено, контрол не нужен (включается через overflow,
    /// и пустота в header'е лучше украшения).
    private var smartSortIndicator: some View {
        Button {
            // Same `.levelChange` for the inverse path — turn smart-sort
            // off via the active-state pill. Both directions of the
            // smart-sort toggle now haptic identically.
            Haptics.impact()
            withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                useSmartSort = false
            }
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.footnote.weight(.medium))
                .foregroundStyle(skin.accentColor)
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xxs)
                .background(
                    Capsule().fill(skin.accentColor.opacity(DS.Opacity.lightFill))
                )
                .overlay(
                    Capsule().strokeBorder(
                        skin.accentColor.opacity(DS.Opacity.softAccent),
                        lineWidth: DS.Border.thin
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // The capacity sections (FITS / spill-over) are computed AFTER
        // smart-sort runs, so within each group the rows are smart-sorted
        // and across groups the boundary marks the capacity cutoff. The
        // tooltip names that interaction so the user understands the «two
        // tops of priority» they see when both signals are active.
        .help("Smart sort active — sorted by priority within each capacity group. Tap to show in user order.")
        .accessibilityLabel("Smart sort active, ordered by priority within capacity groups — tap to disable")
    }

    /// Middot divider used between the three header facts (verdict, count,
    /// urgent). Tertiary tint so it reads as punctuation, not a sibling
    /// piece of information. `accessibilityHidden` keeps VoiceOver from
    /// announcing «middle dot» between every field.
    private var headerSeparator: some View {
        Text("\u{00B7}")
            .font(.footnote)
            .foregroundStyle(skin.resolvedTextTertiary)
            .accessibilityHidden(true)
    }

    /// Fullscreen button — `arrow.up.left.and.arrow.down.right` это родная
    /// macOS-идиома «развернуть на весь экран» (та же стрелка на зелёном
    /// светофоре окна). Пользователь видит знакомый глиф вместо магической
    /// двойной шевронной стрелки.
    private var fullscreenButton: some View {
        Button {
            onEnterFullscreen?()
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.footnote.weight(.medium))
                .foregroundStyle(skin.resolvedTextSecondary)
                .frame(width: DS.Size.iconSmall, height: DS.Size.iconSmall)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open tasks fullscreen")
        .accessibilityLabel("Open tasks fullscreen")
    }

    /// Red «N urgent» pill — acts as a filter toggle. Selected state gets a
    /// filled background so the user can see the filter is engaged; a
    /// second click releases it. Hidden entirely when no urgent tasks exist.
    @ViewBuilder
    private func urgentFilterButton(urgentCount: Int) -> some View {
        Button {
            // `.levelChange` haptic — list narrows/opens, discrete state
            // change. Mirrors `BacklogFullscreenView.urgentFilterButton`.
            Haptics.impact()
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
            // Middot was a leftover from the «Tasks N · 1 urgent» layout —
            // it visually attached the urgent pill to the count when both
            // shared a label. With the «Tasks» word gone, the middot now
            // glues two separate controls together instead of separating
            // them. The natural HStack gap (`DS.Spacing.sm` from the
            // header) does the spacing job better, читая «count · pill»
            // как два самостоятельных объекта.
            Text("\(urgentCount) urgent")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(skin.resolvedDestructiveColor)
                .contentTransition(.numericText())
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

    /// Overflow menu — secondary view controls. Fullscreen-режим переехал
    /// в отдельную кнопку рядом с шевроном — Бирман: умный layer должен
    /// быть единственной точкой, не дублироваться в overflow.
    private var headerOverflowMenu: some View {
        Menu {
            Button {
                // `.levelChange` for sort-order switch — list reorders,
                // discrete state change. Mirrors `BacklogFullscreenView.smartSortButton`.
                Haptics.impact()
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
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Specific to what the menu contains — sort options. The generic
        // «More options» wording invited curiosity without delivering on
        // it; users hovered, opened, and only saw a single toggle. HIG:
        // tooltips should describe what the control does, not where it
        // sits in the layout.
        .help(useSmartSort ? "Sort: smart (deadline + priority)" : "Sort options")
        .accessibilityLabel("Task list sort options")
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

    // MARK: - Task List
    //
    // Two-state user-facing disclosure, driven by `expansion`:
    //
    // - .collapsed: no task rows — only the header is visible,
    //   keeping the card minimal.
    // - .compact: a height-capped ScrollView, ~4 rows visible, the rest
    //   reached by internal scroll. Preserves the timeline strip below.
    //
    // `.expanded` остаётся внутренним состоянием — в него BacklogView
    // временно переключается на время drag'а, чтобы все строки-цели
    // реордера были видны сразу. «Полное раскрытие» как пользовательский
    // жест переехало во fullscreen Backlog (кнопка в header'е).
    //
    // Birman: один шеврон — два смысла («есть список / нет списка»);
    // полноэкранное представление — отдельный аффорданс рядом, не третий
    // клик той же кнопки.

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
                        tombstones
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
        // Single rendering path: the visible task list partitioned by
        // capacity. Smart-sort flattens to score order; otherwise we honour
        // the user's drag order via `groupedByContext` (which clusters but
        // doesn't print headers — context is already on each row's subtitle).
        // Capacity sections compose on top of whichever order applies.
        //
        // Birman: «иерархия из природы данных» — sections fall out of the
        // capacity math; nothing to label as «FITS» (that's the obvious
        // default). Only the overflow gets a printed marker line because
        // that's the surprise the reader needs to see.
        let baseOrder: [BacklogTask]
        if useSmartSort {
            baseOrder = smartSortedActiveTasks
        } else {
            // Honour `groupedByContext` ordering, but respect the urgent-only
            // filter so the partition doesn't include rows the user has
            // hidden — otherwise the marker would read «9h spill over» while
            // showing a list that doesn't contain those 9h.
            let grouped = backlogService.groupedByContext.flatMap(\.tasks)
            if urgentOnlyFilter {
                baseOrder = grouped.filter { isUrgent($0) }
            } else {
                baseOrder = grouped
            }
        }
        let ids: Set<String> = visibleIDs ?? Set(baseOrder.map(\.id))

        let plan = BacklogLogic.CapacitySectionPlan(
            orderedTasks: baseOrder,
            remainingWorkdayMinutes: remainingWorkdayMinutes
        )

        ForEach(plan.fitting) { task in
            if ids.contains(task.id) {
                taskRowBody(task)
            }
        }

        if plan.hasOverflow {
            // Fade the marker to half opacity while a row is being dragged
            // so the user sees the boundaries are recomputing — they're
            // about to re-bucket when the drop lands. `reduceMotion`
            // collapses the fade to a constant opacity (no transition).
            // The plan called for fading section labels; we have only one
            // marker now, but the principle is the same.
            let isDragging = coordinator?.isDraggingTask == true
            SpillOverMarker(
                overflowMinutes: plan.overflowMinutes,
                overflowCount: plan.overflowing.count,
                onSchedule: { await onScheduleBacklog?() },
                onFocusOnDeadlines: plan.overflowHasUrgent ? { await onFocusOnDeadlines?() } : nil
            )
            .padding(.horizontal, DS.Spacing.sm)
            .opacity(isDragging ? DS.Opacity.half : 1)
            .motionAwareAnimation(DS.Animation.quick, value: isDragging, reduceMotion: reduceMotion)
            .transition(.opacity)
        }

        ForEach(plan.overflowing) { task in
            if ids.contains(task.id) {
                taskRowBody(task)
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
            },
            onReschedule: onRescheduleTask.map { handler in { handler(task) } },
            onSetDeadline: { deadlinePickerTask = task },
            onToggleUrgent: { toggleUrgent(task) },
            wasJustDropped: lastDroppedTaskId == task.id,
            defaultTaskDurationMinutes: optimizerService.defaultTaskDurationMinutes
        )
        .focusable()
        .focused($focusedTaskId, equals: task.id)
        .focusEffectDisabled()
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

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

        // Pulse outline on the dropped row so the eye can find where it
        // landed if it crossed sections. The 0.5 s window is enough to
        // register without lingering. `reduceMotion` rules out the
        // animation and falls back to an instant flash via the row's
        // own motion-aware modifier.
        let droppedId = originalTask.id
        lastDroppedTaskId = droppedId
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if lastDroppedTaskId == droppedId {
                lastDroppedTaskId = nil
            }
        }

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

    /// Toggle the «urgent» state on a task by setting (or clearing) a
    /// today-end deadline. The context-menu only surfaces this action when
    /// the task either has no deadline or already has today's deadline (see
    /// `BacklogTaskRow.canToggleUrgent`), so we never silently overwrite a
    /// user-planned future deadline. Persists via `updateTask` and pipes
    /// through the standard undo toast so a misclick is a single Cmd-Z away.
    private func toggleUrgent(_ task: BacklogTask) {
        let snapshot = task
        var updated = task
        let calendar = Calendar.current
        if let deadline = task.deadline, calendar.isDateInToday(deadline) {
            updated.deadline = nil
        } else {
            // End of today — keeps the task urgent for the rest of the
            // workday without claiming an unrealistic morning slot.
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

    // MARK: - Add Task Field

    private var addTaskField: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "plus")
                    .font(.footnote)
                    .foregroundStyle(isInputFocused ? AnyShapeStyle(skin.accentColor) : AnyShapeStyle(skin.resolvedTextSecondary))

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
                        .font(.footnote.weight(.medium).monospacedDigit())
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
            // Idle stroke makes the input read as a field on every wallpaper —
            // without it, the low-opacity fill alone can disappear into busy
            // or dark backgrounds. On focus the stroke thickens and brightens
            // to the accent so the state change is unmistakable. Birman:
            // «поле должно выглядеть как полем», и состояние должно быть
            // постоянно видимым.
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                    .strokeBorder(
                        skin.accentColor.opacity(isInputFocused ? DS.Opacity.softAccent : DS.Opacity.borderIdle),
                        lineWidth: isInputFocused ? DS.Border.selection : DS.Border.standard
                    )
            )
            .motionAwareAnimation(DS.Animation.quick, value: recognizedDurationMinutes, reduceMotion: reduceMotion)
            .motionAwareAnimation(DS.Animation.quick, value: isInputFocused, reduceMotion: reduceMotion)

            // Hint for new users — disappears once they add a task. Birman:
            // empty state should onboard, not blank-out. Two phrasings:
            //   • All-empty (no tombstones, no frozen) → action-oriented
            //     instruction with both add paths named (type vs drag) so
            //     the user sees what they can do.
            //   • Has tombstones / frozen tasks (so they've used the
            //     backlog before) → quieter «No tasks queued» — they know
            //     the affordance, just need the empty-state acknowledged.
            if activeTasks.isEmpty && !isInputFocused {
                Text(emptyBacklogHint)
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .transition(.opacity)
                    .accessibilityLabel(emptyBacklogHint)
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
                .font(.footnote)
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

    /// Plan: 2-tier hint under the empty backlog. First-time users (no
    /// completed-today, no frozen tombstones — i.e. never used the backlog
    /// at all) get the action-oriented onboarding copy that names both
    /// add paths. Returning users with at least one tombstone get the
    /// quieter «No tasks queued» line — they know the affordance, just
    /// need the empty-state acknowledged.
    private var emptyBacklogHint: String {
        let hasEverUsedBacklog = !completedToday.isEmpty
            || !backlogService.frozen.isEmpty
        if hasEverUsedBacklog {
            return "No tasks queued."
        }
        return "Type below to add a task, or drag one in from the timeline."
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
                        // Active CTA gets medium weight so the typing-driven
                        // feedback reads as foreground; the no-slot case stays
                        // regular weight (it's info, not a CTA).
                        .font(isNoSlot ? .footnote : .footnote.weight(.medium))
                    if !isNoSlot {
                        Text("\u{23CE}")
                            .font(.footnote.weight(.semibold))
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

