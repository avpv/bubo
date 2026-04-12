import SwiftUI
import UniformTypeIdentifiers

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
    /// Fired when the user reorders or cross-context-drops a task. Lets the
    /// parent surface an undo toast (it owns `ToastState`); nil disables the
    /// toast but the reorder still happens.
    var onReorderToast: ((_ message: String, _ undo: @escaping () -> Void) -> Void)? = nil
    /// External trigger: set to `true` to focus the "Add task…" field.
    /// BacklogView resets it to `false` after grabbing focus.
    @Binding var focusRequested: Bool
    /// When true, the task list expands automatically on appear if tasks exist.
    /// Used in the empty-calendar state where tasks are the primary content.
    var autoExpand: Bool = false

    @Environment(\.activeSkin) private var skin
    /// Shared drag + ghost-preview state, injected by `MenuBarView` via the
    /// environment. May be nil in previews / settings panes, in which case
    /// the ghost-block and drag-highlighting features silently degrade to
    /// inline text and per-row targeting.
    @Environment(\.backlogCoordinator) private var coordinator

    @State private var newTaskTitle = ""
    @State private var isExpanded = false
    @State private var editingTaskId: String? = nil
    /// Textual ghost — complements the ghost block on the timeline so
    /// assistive technologies and compact layouts still get "Today 14:00".
    @State private var ghostPreviewText: String? = nil
    @State private var ghostPreviewTask: Task<Void, Never>? = nil
    @FocusState private var isInputFocused: Bool

    /// User has already performed at least one drag — used to hide the
    /// onboarding hint once the affordance has been discovered.
    @AppStorage("BuboBacklogHasDragged") private var hasDragged: Bool = false

    /// When true, the full task list is shown (no row-count limit).
    /// Toggled by the "N more tasks…" / "Show fewer" button. Resets
    /// to false when the backlog is collapsed.
    @State private var showAllTasks = false

    /// Default duration applied to new tasks (before parsing).
    /// Kept as a constant so tests and the ghost preview agree.
    static let defaultTaskDurationMinutes: Int = 60

    /// Maximum number of task rows shown in the compact (default)
    /// state before the "N more tasks…" button.
    private static let maxVisibleTasks = 4

    /// Maximum number of task rows visible in the expanded state.
    /// A height-capped ScrollView keeps the timeline reachable.
    private static let maxExpandedTasks = 6

    /// Estimated height of a single task row (content + vertical
    /// padding) used to cap the scroll container in expanded mode.
    private static let taskRowEstimatedHeight: CGFloat = 40

    private var activeTasks: [BacklogTask] {
        backlogService.tasks.filter { $0.status != .done }
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
                if isExpanded {
                    // Compact: plain VStack with maxVisibleTasks rows.
                    // Expanded: height-capped ScrollView so the timeline
                    // stays reachable for drag-to-schedule.
                    taskList
                }
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
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { showAllTasks = false }
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
                isExpanded = true
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
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Tasks")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)

                    let urgent = backlogService.urgent(withinDays: 2)
                    if !urgent.isEmpty {
                        Text("\(urgent.count) urgent")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                    }

                    Text("\(activeTasks.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if !activeTasks.isEmpty {
                Button("Schedule") {
                    onScheduleTasks()
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(skin.accentColor)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.sm)
    }

    // MARK: - Task List
    //
    // Compact mode (default): plain VStack renders only the first
    // `maxVisibleTasks` rows plus a "N more tasks…" toggle. No scroll
    // container → `.onDrag` / `.dropDestination` work unconditionally.
    //
    // Expanded mode: a height-capped ScrollView wraps all rows so the
    // user can browse long lists without pushing the Timeline off
    // screen. The cap is sized for exactly `maxVisibleTasks` rows,
    // keeping free slots reachable for drag-to-schedule.
    //
    // Collapsing the backlog via the header chevron resets
    // `showAllTasks` to false.

    private var taskList: some View {
        let allTasks = activeTasks
        let overflowCount = max(0, allTasks.count - Self.maxVisibleTasks)

        return VStack(spacing: 0) {
            if !hasDragged && !activeTasks.isEmpty {
                dragDiscoveryHint
            }

            // When expanded and there are more tasks than the visible
            // limit, wrap rows in a height-capped ScrollView so the
            // timeline stays reachable for drag-to-schedule.
            if showAllTasks && allTasks.count > Self.maxVisibleTasks {
                ScrollView {
                    taskRowsContent(visibleIDs: nil)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: Self.taskRowEstimatedHeight * CGFloat(Self.maxExpandedTasks))
            } else {
                // Compact mode — plain VStack, only first maxVisibleTasks.
                let visibleIDs = Set(allTasks.prefix(Self.maxVisibleTasks).map(\.id))
                taskRowsContent(visibleIDs: visibleIDs)
            }

            // Overflow toggle — shows when tasks exceed the visible limit
            if overflowCount > 0 && !showAllTasks {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAllTasks = true
                    }
                } label: {
                    Text("\(overflowCount) more task\(overflowCount == 1 ? "" : "s")…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(skin.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.sm)
                }
                .buttonStyle(.plain)
            } else if showAllTasks && allTasks.count > Self.maxVisibleTasks {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAllTasks = false
                    }
                } label: {
                    Text("Show fewer")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xs)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .animation(.easeInOut(duration: 0.2), value: activeTasks.map(\.id))
        .animation(.easeInOut(duration: 0.2), value: showAllTasks)
    }

    /// Renders grouped task rows. When `visibleIDs` is nil all tasks
    /// are rendered (expanded ScrollView mode); otherwise only tasks
    /// whose id is in the set appear (compact mode).
    @ViewBuilder
    private func taskRowsContent(visibleIDs: Set<String>?) -> some View {
        let ids = visibleIDs ?? Set(activeTasks.map(\.id))
        let grouped = backlogService.groupedByContext

        ForEach(grouped, id: \.context) { group in
            let groupHasVisibleTasks = group.tasks.contains { ids.contains($0.id) }

            if let context = group.context, groupHasVisibleTasks {
                Text(context)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .tracking(0.3)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.top, DS.Spacing.sm)
                    .padding(.bottom, DS.Spacing.xxs)
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
                            onComplete: {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    backlogService.completeTask(id: task.id)
                                }
                            },
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
                .foregroundStyle(skin.accentColor.opacity(0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text("Drag a task onto a free slot to schedule it, or onto another task to reorder.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Right-click a task for keyboard-friendly Move Up / Move Down.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(skin.accentColor.opacity(0.05))
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

        withAnimation(.easeInOut(duration: 0.2)) {
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
        onReorderToast?(
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
        withAnimation(.easeInOut(duration: 0.2)) {
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

        let taskId = task.id
        onReorderToast?("Reordered \u{201C}\(task.title)\u{201D}") { [backlogService] in
            guard let previousIndex,
                  let current = backlogService.tasks.first(where: { $0.id == taskId })
            else { return }
            _ = backlogService.removeTask(id: taskId)
            backlogService.restoreTask(current, at: previousIndex)
        }
    }

    private func moveTaskToEdge(_ task: BacklogTask, toTop: Bool) {
        let previousIndex = backlogService.indexOfTask(id: task.id)
        withAnimation(.easeInOut(duration: 0.2)) {
            if toTop {
                if let firstActive = activeTasks.first, firstActive.id != task.id {
                    backlogService.moveTask(id: task.id, before: firstActive.id)
                }
            } else {
                backlogService.moveTaskToEnd(id: task.id)
            }
        }
        let taskId = task.id
        onReorderToast?("Moved \u{201C}\(task.title)\u{201D} to \(toTop ? "top" : "bottom")") { [backlogService] in
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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(skin.accentColor.opacity(isInputFocused ? 0.06 : 0.03))
            )

            // Hint for new users — disappears once they add a task.
            if activeTasks.isEmpty && !isInputFocused {
                Text("Tasks you add here will be scheduled into free slots")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.sm)
        .animation(.easeInOut(duration: 0.15), value: isInputFocused)
    }

    // MARK: - Ghost Preview

    /// Text hint under the input ("Today 14:00–15:00"). Kept in addition to
    /// the timeline ghost block so VoiceOver users, compact layouts, and the
    /// `no free slot this week` fallback still have a visible signal.
    @ViewBuilder
    private var ghostPreviewRow: some View {
        if let preview = ghostPreviewText, !newTaskTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.caption)
                    .foregroundStyle(skin.accentColor.opacity(0.5))

                Text(preview)
                    .font(.caption2)
                    .foregroundStyle(skin.accentColor.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.easeInOut(duration: 0.2), value: preview)
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
        withAnimation(.easeInOut(duration: 0.2)) {
            backlogService.addTask(task)
            isExpanded = true
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
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 28)
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
                        Text("\(task.durationMinutes)m")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xs)
                    .background(.ultraThinMaterial, in: Capsule())
                    .onDisappear { onDragEnd() }
                }

            // Checkbox — complete on tap
            Button(action: onComplete) {
                Image(systemName: "circle")
                    .font(.callout)
                    .foregroundStyle(isUrgent ? .red : .secondary)
            }
            .buttonStyle(.plain)

            // Content — edit on tap
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: DS.Spacing.xs) {
                        Text("\(task.durationMinutes)m")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if task.priority == .high {
                            Text("!")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.red)
                        }

                        if let sp = task.storyPoints {
                            Text("\(sp)sp")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let deadline = task.deadline {
                            Text(deadlineLabel(deadline))
                                .font(.caption2)
                                .foregroundStyle(isUrgent ? .red : .secondary)
                        }

                        if let context = task.context {
                            Text(context)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Reorder + delete controls — visible on hover
            if isHovered {
                HStack(spacing: DS.Spacing.xxs) {
                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.up")
                            .font(.caption2)
                            .foregroundStyle(canMoveUp ? .secondary : .quaternary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveUp)
                    .help("Move up")

                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(canMoveDown ? .secondary : .quaternary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveDown)
                    .help("Move down")

                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .padding(.horizontal, DS.Spacing.xs)
        .contentShape(Rectangle())
        .opacity(isDragging ? 0.4 : 1)
        .background(
            // Reorder drop highlight — a thin accent bar at the top edge so
            // the user sees exactly where the dropped task will land.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(skin.accentColor.opacity(isReorderTargeted ? 0.10 : 0))
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(skin.accentColor)
                .frame(height: isReorderTargeted ? 2 : 0)
                .animation(.easeInOut(duration: 0.12), value: isReorderTargeted)
        }
        .onHover { isHovered = $0 }
        .dropDestination(for: BacklogTaskDrag.self) { items, _ in
            guard let dropped = items.first, dropped.taskId != task.id else { return false }
            onReorderDrop(dropped)
            return true
        } isTargeted: { targeted in
            withAnimation(.easeInOut(duration: 0.12)) {
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
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInTomorrow(date) { return "tomorrow" }
        if date < now { return "overdue" }
        let days = cal.dateComponents([.day], from: now, to: date).day ?? 0
        return "\(days)d"
    }
}

// MARK: - Backlog Task Edit Row (Inline)

/// Inline editing row — replaces the task row in-place.
/// All properties editable without leaving the main screen (Birman: no modality).
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

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Title
            TextField("Task name", text: $title)
                .textFieldStyle(.plain)
                .font(.callout.weight(.medium))
                .focused($isTitleFocused)
                .onSubmit { save() }

            // Duration pills
            VStack(alignment: .leading, spacing: 2) {
                Text("Duration")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(Self.durationOptions, id: \.self) { mins in
                            chipButton(
                                label: mins < 60 ? "\(mins)m" : "\(mins / 60)h\(mins % 60 > 0 ? "\(mins % 60)m" : "")",
                                isActive: durationMinutes == mins
                            ) { durationMinutes = mins }
                        }
                    }
                }
            }

            // Priority pills
            VStack(alignment: .leading, spacing: 2) {
                Text("Priority")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(TaskPriority.allCases, id: \.self) { p in
                        chipButton(label: p.label, isActive: priority == p) {
                            priority = p
                        }
                    }
                }
            }

            // Story points
            VStack(alignment: .leading, spacing: 2) {
                Text("Story points")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(Self.spOptions, id: \.self) { sp in
                        chipButton(
                            label: sp.map { "\($0)" } ?? "—",
                            isActive: storyPoints == sp
                        ) { storyPoints = sp }
                    }
                }
            }

            // Deadline toggle + picker
            HStack {
                Toggle("Deadline", isOn: $hasDeadline)
                    .font(.caption2)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                if hasDeadline {
                    DatePicker("", selection: Binding(
                        get: { deadline ?? Date() },
                        set: { deadline = $0 }
                    ), displayedComponents: .date)
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            // Context
            HStack(spacing: DS.Spacing.xs) {
                Text("Project")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("optional", text: $context)
                    .textFieldStyle(.plain)
                    .font(.caption2)
                    .frame(maxWidth: 120)
            }

            // Save / Cancel
            HStack {
                Spacer()
                Button("Cancel") { onDone() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Save") { save() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(skin.accentColor)
            }
        }
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(skin.accentColor.opacity(0.04))
        )
        .onAppear { isTitleFocused = true }
    }

    private func save() {
        var updated = task
        updated.title = title.trimmingCharacters(in: .whitespaces)
        guard !updated.title.isEmpty else { return }
        updated.durationMinutes = durationMinutes
        updated.priority = priority
        updated.deadline = hasDeadline ? (deadline ?? Date()) : nil
        updated.context = context.isEmpty ? nil : context
        updated.storyPoints = storyPoints
        backlogService.updateTask(updated)
        onDone()
    }

    private func chipButton(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(isActive ? Color.white : .primary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isActive ? skin.accentColor : skin.accentColor.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
    }
}
