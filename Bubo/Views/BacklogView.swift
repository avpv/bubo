import SwiftUI
import UniformTypeIdentifiers

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
    /// Hover state for the Schedule pill — HIG: primary actions should read as
    /// buttons, so a subtle capsule фон появляется на наведении.
    @State private var isScheduleHovering: Bool = false
    /// Textual ghost — complements the ghost block on the timeline so
    /// assistive technologies and compact layouts still get "Today 14:00".
    @State private var ghostPreviewText: String? = nil
    @State private var ghostPreviewTask: Task<Void, Never>? = nil
    @FocusState private var isInputFocused: Bool

    /// User has already performed at least one drag — used to hide the
    /// onboarding hint once the affordance has been discovered.
    @AppStorage("BuboBacklogHasDragged") private var hasDragged: Bool = false

    /// Default duration applied to new tasks (before parsing).
    /// Kept as a constant so tests and the ghost preview agree.
    static let defaultTaskDurationMinutes: Int = 60

    /// Maximum number of task rows visible in the compact expansion state.
    /// A height-capped ScrollView keeps the timeline reachable.
    private static let maxExpandedTasks = 4

    /// Hard ceiling for the fully-expanded state so the timeline below always
    /// retains a usable strip. Generous enough for ~10–11 rows; anything
    /// longer falls back to internal scrolling.
    private static let fullyExpandedMaxHeight: CGFloat = 520

    private var activeTasks: [BacklogTask] {
        backlogService.tasks.filter { $0.status != .done }
    }

    /// Height cap for the task list ScrollView.
    ///
    /// - `.compact`: sums the first `maxExpandedTasks` row heights so the
    ///   visible area always fits 4 task rows, keeping the timeline reachable.
    /// - `.expanded`: `min(contentHeight, fullyExpandedMaxHeight)` — shows
    ///   every task up to a generous cap, longer lists scroll internally.
    /// - `.collapsed`: zero (list hidden entirely).
    private var scrollMaxHeight: CGFloat {
        // Row height estimate: backlogRowHeight is the frame minHeight (44pt)
        // but the two-line content + vertical padding can push the actual
        // height a few points higher depending on platform font metrics.
        let rowHeight = DS.Size.backlogRowHeight + DS.Spacing.xs // 48pt
        let activeCount = activeTasks.count
        guard activeCount > 0 else { return 0 }

        switch expansion {
        case .collapsed:
            return 0
        case .compact:
            let visible = min(activeCount, Self.maxExpandedTasks)
            return rowHeight * CGFloat(visible)
        case .expanded:
            let content = rowHeight * CGFloat(activeCount)
            return min(content, Self.fullyExpandedMaxHeight)
        }
    }

    /// Duration to use for ghost-preview lookup and for the task actually
    /// created on submit. Reparses on every keystroke.
    private var parsedDurationMinutes: Int {
        BacklogTitleParser.parse(newTaskTitle).durationMinutes ?? Self.defaultTaskDurationMinutes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !activeTasks.isEmpty || isInputFocused {
                backlogHeader
                // Task rows only appear when expanded (up to 4 visible
                // with scroll); collapsed = header only.
                taskList
            }
            addTaskField
            ghostPreviewRow
        }
        .onChange(of: focusRequested) { _, requested in
            if requested {
                isInputFocused = true
                focusRequested = false
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
            if autoExpand && !activeTasks.isEmpty {
                expansion = .compact
            }
        }
        .onDisappear {
            coordinator?.clearGhost()
            coordinator?.endDrag()
            ghostPreviewTask?.cancel()
        }
    }

    // MARK: - Header

    private var backlogHeader: some View {
        HStack(spacing: DS.Spacing.sm) {
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

                    let urgent = backlogService.urgent(withinDays: 2)
                    if !urgent.isEmpty {
                        Text("\(urgent.count) urgent")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(skin.resolvedDestructiveColor)
                    } else {
                        // Birman: one signal, not two competing numbers. Show
                        // the urgent count when it matters, total otherwise.
                        // Плоская цифра без капсулы — капсула оставлена
                        // только для urgent, где она несёт тревожный акцент.
                        Text("\(activeTasks.count)")
                            .font(.subheadline.weight(.regular))
                            .foregroundStyle(skin.resolvedTextTertiary)
                            .contentTransition(.numericText())
                    }
                }
            }
            .buttonStyle(.plain)
            .help(expansion.accessibilityHint)

            Spacer()

            if !activeTasks.isEmpty {
                scheduleButton
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.sm)
    }

    /// HIG: главное действие должно читаться как кнопка. Tint + hover-капсула
    /// дают affordance без тяжёлой заливки на покое.
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
                        .fill(skin.accentColor.opacity(isScheduleHovering ? 0.14 : 0))
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
        let allTasks = activeTasks

        return VStack(spacing: 0) {
            if expansion != .collapsed {
                if !hasDragged && !allTasks.isEmpty {
                    dragDiscoveryHint
                }

                ScrollView {
                    VStack(spacing: 0) {
                        taskRowsContent(visibleIDs: nil)
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
        let ids = visibleIDs ?? Set(activeTasks.map(\.id))
        let grouped = backlogService.groupedByContext

        ForEach(grouped, id: \.context) { group in
            ForEach(group.tasks) { task in
                if ids.contains(task.id) {
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
                            onComplete: { completeTaskWithUndo(task) },
                            onEdit: { editingTaskId = task.id },
                            onDelete: { onDeleteTask?(task) },
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
                            onMoveToBottom: { moveTaskToEdge(task, toTop: false) }
                        )
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
            }
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

    /// One-time onboarding hint: explains the drag gestures and keyboard
    /// alternatives. Disappears permanently after the first drag.
    private var dragDiscoveryHint: some View {
        HStack(alignment: .top, spacing: DS.Spacing.xs) {
            Image(systemName: "hand.draw")
                .font(.caption2)
                .foregroundStyle(skin.accentColor.opacity(DS.Opacity.accentMuted))
            // Birman: один короткий совет вместо двух абзацев. Клавиатурный
            // путь и так пропадёт из хинта, когда пользователь применит его
            // через контекстное меню (см. `moveTask` / `moveTaskToEdge`).
            Text("Drag a task onto a free slot to schedule it, or onto another to reorder.")
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                .fill(skin.accentColor.opacity(DS.Opacity.subtleFill))
        )
        .padding(.top, DS.Spacing.xxs)
        .padding(.bottom, DS.Spacing.xs)
        .transition(.opacity)
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

    // MARK: - Add Task Field

    private var addTaskField: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(isInputFocused ? AnyShapeStyle(skin.accentColor) : AnyShapeStyle(.tertiary))

                TextField("Add task\u{2026}", text: $newTaskTitle)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($isInputFocused)
                    .onSubmit { addTask() }
                    .onChange(of: newTaskTitle) {
                        computeGhostPreview()
                    }
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                    .fill(skin.accentColor.opacity(isInputFocused ? DS.Opacity.lightFill : DS.Opacity.subtleFill))
            )

            // Hint for new users — disappears once they add a task.
            if activeTasks.isEmpty && !isInputFocused {
                Text("Tasks you add here will be scheduled into free slots")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.sm)
        .motionAwareAnimation(DS.Animation.quick, value: isInputFocused, reduceMotion: reduceMotion)
    }

    // MARK: - Ghost Preview

    /// Text hint under the input ("Today 14:00–15:00"). Kept in addition to
    /// the timeline ghost block so VoiceOver users, compact layouts, and the
    /// `no free slot this week` fallback still have a visible signal.
    @ViewBuilder
    private var ghostPreviewRow: some View {
        if let preview = ghostPreviewText, !newTaskTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            // Birman: текст сам по себе несёт смысл ("Today 14:00–15:00");
            // декоративная иконка-стрелка только создавала шум. Убрана.
            Text(preview)
                .font(.caption2)
                .foregroundStyle(skin.accentColor.opacity(DS.Opacity.accentMuted))
                .lineLimit(1)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .motionAwareAnimation(DS.Animation.standard, value: preview, reduceMotion: reduceMotion)
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
    var onComplete: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
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

    @State private var isHovered = false
    @State private var isReorderTargeted = false
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            // Drag handle — the ONLY drag source on this row.
            //
            // Uses .onDrag (NSItemProvider API) instead of .draggable
            // (Transferable API). On macOS, .draggable() fails to start
            // NSDrag sessions inside popover windows and when competing
            // with child gestures. .onDrag uses NSItemProvider directly,
            // bypassing the Transferable encoding path that silently
            // breaks in these contexts.
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                // Birman: affordance you have to search for isn't an
                // affordance. The handle is always visible (quietly, at
                // `softAccent`), becoming fully opaque on hover so users
                // see "I can grab this" without having to hover first.
                .foregroundStyle(skin.resolvedTextTertiary)
                .frame(width: DS.Size.iconLarge, height: DS.Size.accentBarHeight)
                .contentShape(Rectangle())
                .opacity(isHovered ? 1 : DS.Opacity.softAccent)
                .motionAwareAnimation(DS.Animation.quick, value: isHovered, reduceMotion: reduceMotion)
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
                        // DS.formatMinutes keeps the same non-breaking-space
                        // format used everywhere else in the app.
                        Text(DS.formatMinutes(task.durationMinutes))
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedTextSecondary)
                    }
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xs)
                    // Use the skin's resolved button material so the drag
                    // ghost reads as "part of this app", not as a generic
                    // macOS blur.
                    .background(skin.resolvedButtonMaterial, in: Capsule())
                    .onDisappear { onDragEnd() }
                }

            // Checkbox — complete on tap
            Button(action: onComplete) {
                Image(systemName: "circle")
                    .font(.callout)
                    .foregroundStyle(isUrgent ? skin.resolvedDestructiveColor : skin.resolvedTextSecondary)
            }
            .buttonStyle(.plain)
            .help("Mark complete")
            .accessibilityLabel("Mark \u{201C}\(task.title)\u{201D} complete")

            // Content — edit on tap
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    HStack(spacing: DS.Spacing.xs) {
                        // Birman: priority is a quiet, semantic marker — a
                        // colored dot at the leading edge, not an exclamation
                        // mark hack. Only shown for `.high` (absence = ok).
                        if task.priority == .high {
                            Circle()
                                .fill(skin.resolvedDestructiveColor)
                                .frame(width: DS.Size.recipeDotSize, height: DS.Size.recipeDotSize)
                                .accessibilityLabel("High priority")
                        }
                        Text(task.title)
                            .font(.callout)
                            .foregroundStyle(skin.resolvedTextPrimary)
                            .lineLimit(1)
                    }

                    HStack(spacing: DS.Spacing.xs) {
                        // Uses DS.formatMinutes so "1 h 30 min" has the same
                        // non-breaking-space treatment as the rest of the app.
                        Text(DS.formatMinutes(task.durationMinutes))
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedTextSecondary)

                        if let sp = task.storyPoints {
                            Text("\(sp)\u{00A0}sp")
                                .font(.caption2)
                                .foregroundStyle(skin.resolvedTextSecondary)
                        }

                        if let deadline = task.deadline {
                            Text(deadlineLabel(deadline))
                                .font(.caption2)
                                .foregroundStyle(isUrgent ? skin.resolvedDestructiveColor : skin.resolvedTextSecondary)
                        }

                        if let context = task.context {
                            Text(context)
                                .font(.caption2)
                                .foregroundStyle(skin.resolvedTextTertiary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityRowLabel)
            .accessibilityHint("Double-tap to edit")

            Spacer()

            // Reorder + delete controls. HIG: reserve the space so the
            // layout doesn't jump when the cursor enters/leaves — fade
            // opacity instead (Apple Reminders / Things pattern).
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
            .motionAwareAnimation(DS.Animation.quick, value: isHovered, reduceMotion: reduceMotion)
            // Keep the controls out of the accessibility tree when hidden
            // so VoiceOver doesn't announce ghost buttons.
            .accessibilityHidden(!isHovered)
        }
        .padding(.vertical, DS.Spacing.xs)
        .padding(.horizontal, DS.Spacing.xs)
        .frame(minHeight: DS.Size.backlogRowHeight)
        .contentShape(Rectangle())
        .opacity(isDragging ? DS.Opacity.tertiaryText : 1)
        .background(
            // Reorder drop highlight — a thin accent bar at the top edge so
            // the user sees exactly where the dropped task will land.
            RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                .fill(skin.accentColor.opacity(isReorderTargeted ? DS.Opacity.lightFill : 0))
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(skin.accentColor)
                .frame(height: isReorderTargeted ? DS.Border.selection : 0)
                .motionAwareAnimation(DS.Animation.quick, value: isReorderTargeted, reduceMotion: reduceMotion)
        }
        .onHover { isHovered = $0 }
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
            // Keyboard-friendly reorder. Shortcut bindings aren't attached
            // here because context menus are ephemeral — the shortcuts
            // would only work while the menu itself is open, which is the
            // opposite of useful. VoiceOver users reach the same actions
            // through the `accessibilityAction` modifiers below.
            Button("Move Up") { onMoveUp() }
                .disabled(!canMoveUp)
            Button("Move Down") { onMoveDown() }
                .disabled(!canMoveDown)
            Button("Move to Top") { onMoveToTop() }
                .disabled(!canMoveUp)
            Button("Move to Bottom") { onMoveToBottom() }
                .disabled(!canMoveDown)
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
        .accessibilityAction(named: "Move Up") { onMoveUp() }
        .accessibilityAction(named: "Move Down") { onMoveDown() }
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
        backlogService.updateTask(updated)
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
