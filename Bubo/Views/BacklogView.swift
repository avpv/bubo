import SwiftUI

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
    /// External trigger: set to `true` to focus the "Add task…" field.
    /// BacklogView resets it to `false` after grabbing focus.
    @Binding var focusRequested: Bool
    /// When true, the task list expands automatically on appear if tasks exist.
    /// Used in the empty-calendar state where tasks are the primary content.
    var autoExpand: Bool = false

    @Environment(\.activeSkin) private var skin
    @State private var newTaskTitle = ""
    @State private var isExpanded = false
    @State private var editingTaskId: String? = nil
    @State private var ghostPreview: String? = nil
    @State private var ghostPreviewTask: Task<Void, Never>? = nil
    @FocusState private var isInputFocused: Bool

    /// Currently dragged task ID (for drag-to-schedule).
    @State private var draggingTaskId: String? = nil

    private var activeTasks: [BacklogTask] {
        backlogService.tasks.filter { $0.status != .done }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !activeTasks.isEmpty || isInputFocused {
                backlogHeader
                if isExpanded {
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
        .onAppear {
            if autoExpand && !activeTasks.isEmpty {
                isExpanded = true
            }
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
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
    }

    // MARK: - Task List

    private var taskList: some View {
        VStack(spacing: 0) {
            let grouped = backlogService.groupedByContext
            ForEach(grouped, id: \.context) { group in
                if let context = group.context {
                    Text(context)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .tracking(0.3)
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.top, DS.Spacing.sm)
                        .padding(.bottom, DS.Spacing.xxs)
                }

                ForEach(group.tasks) { task in
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
                            onComplete: {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    backlogService.completeTask(id: task.id)
                                }
                            },
                            onEdit: { editingTaskId = task.id },
                            onDelete: { onDeleteTask?(task) }
                        )
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .animation(.easeInOut(duration: 0.2), value: activeTasks.map(\.id))
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
                    .foregroundStyle(.tertiary)

                TextField("Add task...", text: $newTaskTitle)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($isInputFocused)
                    .onSubmit { addTask() }
                    .onChange(of: newTaskTitle) {
                        computeGhostPreview()
                    }
            }

            // Hint for new users — disappears once they add a task.
            if activeTasks.isEmpty && !isInputFocused {
                Text("Tasks you add here will be scheduled into free slots")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
    }

    // MARK: - Ghost Preview

    /// Shows where a new task would land in the schedule while the user is typing.
    /// Birman: "sequential magic" — anticipate the result before the action completes.
    @ViewBuilder
    private var ghostPreviewRow: some View {
        if let preview = ghostPreview, !newTaskTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.caption)
                    .foregroundStyle(skin.accentColor.opacity(0.5))

                Text(preview)
                    .font(.caption2)
                    .foregroundStyle(skin.accentColor.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.xxs)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.easeInOut(duration: 0.2), value: preview)
        }
    }

    private func computeGhostPreview() {
        ghostPreviewTask?.cancel()
        let title = newTaskTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            ghostPreview = nil
            return
        }

        ghostPreviewTask = Task { @MainActor in
            // Debounce: wait 300ms after last keystroke
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            // Find the next free slot heuristically (no GA, instant)
            let slot = findNextFreeSlot(durationMinutes: 60)
            guard !Task.isCancelled else { return }

            if let slot {
                let fmt = DateFormatter()
                fmt.setLocalizedDateFormatFromTemplate("H:mm")
                ghostPreview = "\(fmt.string(from: slot.start))–\(fmt.string(from: slot.end))"
            } else {
                ghostPreview = "no free slot today"
            }
        }
    }

    /// Fast heuristic: find the next free slot in today's schedule.
    /// No GA — just gap detection between events.
    private func findNextFreeSlot(durationMinutes: Int) -> DateInterval? {
        let cal = Calendar.current
        let now = Date()
        let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let workEnd = cal.date(
            bySettingHour: optimizerService.workingHoursEnd,
            minute: 0, second: 0, of: now
        ) ?? todayEnd
        let effectiveEnd = min(workEnd, todayEnd)

        let events = reminderService.allEvents
            .filter { $0.startDate >= now && $0.startDate < effectiveEnd }
            .sorted { $0.startDate < $1.startDate }

        let needed = TimeInterval(durationMinutes * 60)
        var cursor = now

        // Snap cursor to next half-hour
        let minute = cal.component(.minute, from: cursor)
        if minute > 0 && minute <= 30 {
            cursor = cal.date(bySettingHour: cal.component(.hour, from: cursor),
                             minute: 30, second: 0, of: cursor) ?? cursor
        } else if minute > 30 {
            cursor = cal.date(byAdding: .hour, value: 1, to:
                cal.date(bySettingHour: cal.component(.hour, from: cursor),
                         minute: 0, second: 0, of: cursor) ?? cursor) ?? cursor
        }

        for event in events {
            let gap = event.startDate.timeIntervalSince(cursor)
            if gap >= needed {
                return DateInterval(start: cursor, duration: needed)
            }
            cursor = max(cursor, event.endDate)
        }

        // Check trailing gap
        if effectiveEnd.timeIntervalSince(cursor) >= needed {
            return DateInterval(start: cursor, duration: needed)
        }

        return nil
    }

    private func addTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }

        let task = BacklogTask(
            title: title,
            durationMinutes: 60,
            priority: .medium
        )
        withAnimation(.easeInOut(duration: 0.2)) {
            backlogService.addTask(task)
            isExpanded = true
        }
        newTaskTitle = ""
        ghostPreview = nil
        ghostPreviewTask?.cancel()
    }
}

// MARK: - Backlog Task Row

struct BacklogTaskRow: View {
    let task: BacklogTask
    let isUrgent: Bool
    var onComplete: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    @State private var isHovered = false
    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
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

            // Delete on hover
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .draggable(task.id) {
            // Drag preview — lightweight label shown while dragging
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
        }
        .contextMenu {
            Button("Complete") { onComplete() }
            Button("Edit") { onEdit() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
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
