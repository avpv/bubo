import SwiftUI

// MARK: - Backlog View

/// Inline backlog panel for the main screen.
/// Shows pending tasks with inline editing — no modal, no separate screen.
/// Tasks are persistent and automatically flow into the schedule.
///
/// Design principles (Birman):
/// - No modality: editing happens inline
/// - Data is precious: tasks persist until completed
/// - Undo instead of confirmation: deletions are undoable via toast
/// - Meaningful grouping: by urgency and project, not arbitrary categories
struct BacklogView: View {
    var backlogService: BacklogService
    var optimizerService: OptimizerService
    var reminderService: ReminderService
    var onScheduleTasks: () -> Void
    var onDeleteTask: ((BacklogTask) -> Void)?

    @Environment(\.activeSkin) private var skin
    @State private var newTaskTitle = ""
    @State private var isExpanded = true
    @FocusState private var isInputFocused: Bool

    private var pendingTasks: [BacklogTask] {
        backlogService.tasks.filter { $0.status != .done }
    }

    var body: some View {
        if !pendingTasks.isEmpty || isInputFocused {
            VStack(alignment: .leading, spacing: 0) {
                backlogHeader
                if isExpanded {
                    taskList
                    addTaskField
                }
            }
        } else {
            // Collapsed: just the add field
            addTaskField
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
                    Text("\(pendingTasks.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if !pendingTasks.isEmpty {
                Button("Schedule") {
                    onScheduleTasks()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(skin.accentColor)
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
    }

    // MARK: - Task List

    private var taskList: some View {
        VStack(spacing: 1) {
            // Urgent tasks first
            let urgent = pendingTasks.filter { task in
                guard let deadline = task.deadline else { return false }
                return deadline <= Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date()
            }
            let regular = pendingTasks.filter { task in
                guard let deadline = task.deadline else { return true }
                return deadline > Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date()
            }

            if !urgent.isEmpty {
                ForEach(urgent) { task in
                    BacklogTaskRow(
                        task: task,
                        isUrgent: true,
                        onComplete: { backlogService.completeTask(id: task.id) },
                        onDelete: { onDeleteTask?(task) }
                    )
                }
            }

            ForEach(regular) { task in
                BacklogTaskRow(
                    task: task,
                    isUrgent: false,
                    onComplete: { backlogService.completeTask(id: task.id) },
                    onDelete: { onDeleteTask?(task) }
                )
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
    }

    // MARK: - Add Task Field

    private var addTaskField: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "plus")
                .font(.caption)
                .foregroundStyle(.tertiary)

            TextField("Add task...", text: $newTaskTitle)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isInputFocused)
                .onSubmit {
                    addTask()
                }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
    }

    // MARK: - Actions

    private func addTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }

        let task = BacklogTask(
            title: title,
            durationMinutes: 60,
            priority: .medium
        )
        backlogService.addTask(task)
        newTaskTitle = ""
    }
}

// MARK: - Backlog Task Row

struct BacklogTaskRow: View {
    let task: BacklogTask
    let isUrgent: Bool
    var onComplete: () -> Void
    var onDelete: () -> Void

    @State private var isHovered = false
    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            // Checkbox
            Button(action: onComplete) {
                Image(systemName: "circle")
                    .font(.callout)
                    .foregroundStyle(isUrgent ? .red : .secondary)
            }
            .buttonStyle(.plain)

            // Title
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.callout)
                    .lineLimit(1)

                HStack(spacing: DS.Spacing.xs) {
                    // Duration
                    Text("\(task.durationMinutes)m")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    // Priority indicator
                    if task.priority == .high {
                        Text("!")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.red)
                    }

                    // Deadline
                    if let deadline = task.deadline {
                        Text(deadlineLabel(deadline))
                            .font(.caption2)
                            .foregroundStyle(isUrgent ? .red : .secondary)
                    }

                    // Context
                    if let context = task.context {
                        Text(context)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Delete (on hover)
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Complete") { onComplete() }
            Divider()
            Menu("Priority") {
                Button("High") {}
                Button("Medium") {}
                Button("Low") {}
            }
            Menu("Duration") {
                ForEach([15, 30, 60, 90, 120, 180], id: \.self) { min in
                    Button("\(min) min") {}
                }
            }
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
