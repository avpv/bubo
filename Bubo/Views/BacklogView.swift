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
    /// Row-level keyboard focus. `nil` when no row owns focus (e.g., input
    /// field is focused instead). Driven by ↑ / ↓ in rows and by clicks.
    @FocusState private var focusedTaskId: String?
    /// Whether the "N completed today" tombstone is expanded. Collapsed by
    /// default so finished work doesn't crowd the active list.
    @State private var showCompletedToday: Bool = false

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
    /// retains a usable strip. Generous enough for ~12 rows; anything
    /// longer falls back to internal scrolling.
    private static let fullyExpandedMaxHeight: CGFloat = 480

    /// Single-line row height. Lower than the former 44pt because the row
    /// is now one line (title + inline middot-separated metadata) instead
    /// of a two-line stack.
    static let compactRowHeight: CGFloat = 40

    private var activeTasks: [BacklogTask] {
        backlogService.tasks.filter { $0.status != .done }
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

    /// Same as `parsedDurationMinutes` but returns `nil` when the parser
    /// didn't recognize an explicit duration. Drives the inline chip that
    /// echoes what the parser understood — seeing "30 min" appear confirms
    /// the shorthand was caught before the user commits.
    private var recognizedDurationMinutes: Int? {
        BacklogTitleParser.parse(newTaskTitle).durationMinutes
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

                    // Total count — always shown, tabular digits so the number
                    // doesn't jitter horizontally when `.numericText()` rolls.
                    Text("\(activeTasks.count)")
                        .font(.subheadline.weight(.regular).monospacedDigit())
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .contentTransition(.numericText())

                    // Additional red "urgent" signal appears only when it
                    // matters — it augments the total rather than replacing
                    // it, so the user never loses "how many tasks total".
                    let urgent = backlogService.urgent(withinDays: 2)
                    if !urgent.isEmpty {
                        Text("\(urgent.count) urgent")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(skin.resolvedDestructiveColor)
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
                        completedTombstone
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
    /// Context-group headers restore the visible grouping: когда задача
    /// принадлежит проекту / напоминаниям, заголовок группы поясняет «чьё
    /// это», а сами строки больше не повторяют ярлык у себя в метаданных.
    /// Birman: один голос на информацию — либо заголовок, либо в строке,
    /// но не оба сразу.
    @ViewBuilder
    private func taskRowsContent(visibleIDs: Set<String>?) -> some View {
        let ids = visibleIDs ?? Set(activeTasks.map(\.id))
        let grouped = backlogService.groupedByContext

        ForEach(grouped, id: \.context) { group in
            let groupHasVisibleTasks = group.tasks.contains { ids.contains($0.id) }

            if let context = group.context, groupHasVisibleTasks {
                // Тихий subhead, выровнен по левому краю в одну линию с
                // названиями задач. `frame(maxWidth: .infinity, alignment:
                // .leading)` нужен, потому что родительский VStack —
                // center-aligned, и без него заголовок вставал по центру.
                Text(context)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .textCase(.uppercase)
                    .tracking(0.3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xs)
            }

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
                            onMoveToBottom: { moveTaskToEdge(task, toTop: false) },
                            isFocused: focusedTaskId == task.id,
                            onFocusPrev: { focusRow(offsetFrom: task.id, by: -1) },
                            onFocusNext: { focusRow(offsetFrom: task.id, by: +1) }
                        )
                        .focusable()
                        .focused($focusedTaskId, equals: task.id)
                        .focusEffectDisabled()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
            }
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
    /// True when this row owns keyboard focus — drives the focus ring visual.
    var isFocused: Bool = false
    /// Move focus to the previous / next visible row. Called on plain ↑ / ↓
    /// (without Cmd) so keyboard navigation feels like List without the
    /// constraints of wrapping the backlog in a real List.
    var onFocusPrev: () -> Void = {}
    var onFocusNext: () -> Void = {}

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
    /// `context` не включён — его уже несёт заголовок группы сверху, двойное
    /// упоминание было бы шумом.
    private var metaText: Text {
        let dot = Text("\u{00A0}·\u{00A0}").foregroundStyle(skin.resolvedTextTertiary)

        var out = Text(DS.formatMinutes(task.durationMinutes))
            .foregroundStyle(skin.resolvedTextSecondary)

        if let sp = task.storyPoints {
            out = out + dot + Text("\(sp)\u{00A0}sp")
                .foregroundStyle(skin.resolvedTextSecondary)
        }
        if let deadline = task.deadline {
            let color: Color = isUrgent
                ? skin.resolvedDestructiveColor
                : skin.resolvedTextSecondary
            out = out + dot + Text(deadlineLabel(deadline))
                .foregroundStyle(color)
        }
        return out
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
            dragHandle
            checkbox
            content
            Spacer(minLength: DS.Spacing.xs)
            controls
        }
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.xs)
        .frame(minHeight: BacklogView.compactRowHeight)
        .contentShape(Rectangle())
        .opacity(isDragging ? DS.Opacity.tertiaryText : 1)
        .background(rowBackground)
        .overlay(alignment: .top) { dropBar }
        .overlay { focusRing }
        .onHover { hovering in
            withAnimation(DS.Animation.motionAware(DS.Animation.quick, reduceMotion: reduceMotion)) {
                isHovered = hovering
            }
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
                onDelete()
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
    /// шумом. Курсор и так подскажет grab при наведении; онбординг отдельной
    /// подсказкой через `dragDiscoveryHint` в родителе.
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
    private var content: some View {
        Button(action: onEdit) {
            HStack(spacing: DS.Spacing.xs) {
                Text(task.title)
                    .font(.callout)
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)

                if task.priority == .high {
                    Circle()
                        .fill(skin.resolvedDestructiveColor)
                        .frame(width: DS.Size.recipeDotSize, height: DS.Size.recipeDotSize)
                        .accessibilityLabel("High priority")
                }

                metaText
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityRowLabel)
        .accessibilityHint("Double-tap to edit")
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
