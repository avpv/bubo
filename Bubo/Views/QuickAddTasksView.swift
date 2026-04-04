import SwiftUI

// MARK: - Quick Add Tasks View

/// Batch entry of multiple tasks, then optimize them all at once.
struct QuickAddTasksView: View {
    @Environment(\.activeSkin) private var skin
    var optimizerService: OptimizerService
    var reminderService: ReminderService
    var onBack: () -> Void
    var onShowResults: (() -> Void)? = nil

    @State private var tasks: [TaskEntry] = [TaskEntry()]
    @State private var horizon: Horizon = .today
    @State private var isOptimizing = false
    @State private var showResults = false

    struct TaskEntry: Identifiable {
        let id = UUID()
        var title: String = ""
        var minutes: Int = 60
        var priority: TaskPriority = .medium
        var storyPoints: Int? = nil
    }

    static let fibonacciPoints = [1, 2, 3, 5, 8, 13]

    enum TaskPriority: String, CaseIterable {
        case low = "Low"
        case medium = "Med"
        case high = "High"

        var value: Double {
            switch self {
            case .low: return 0.3
            case .medium: return 0.5
            case .high: return 0.9
            }
        }

        var icon: String {
            switch self {
            case .low: return "arrow.down"
            case .medium: return "minus"
            case .high: return "exclamationmark"
            }
        }
    }

    private var validTasks: [TaskEntry] {
        tasks.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader(
                title: "Quick Add Tasks",
                showBack: true,
                onBack: onBack
            )

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    // Horizon picker
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Plan for")
                            .font(.headline)
                            .foregroundStyle(skin.resolvedTextPrimary)
                            .accessibilityAddTraits(.isHeader)

                        Picker("Planning horizon", selection: $horizon) {
                            Text("Today").tag(Horizon.today)
                            Text("This Week").tag(Horizon.week)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .staggeredEntrance(index: 0)

                    // Tasks section
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Tasks")
                            .font(.headline)
                            .foregroundStyle(skin.resolvedTextPrimary)
                            .accessibilityAddTraits(.isHeader)

                        VStack(spacing: 0) {
                            ForEach(Array($tasks.enumerated()), id: \.element.id) { index, $task in
                                taskRow(task: $task)
                                    .staggeredEntrance(index: index)
                                    .eventScrollTransition()

                                if index < tasks.count - 1 {
                                    SkinSeparator()
                                        .padding(.horizontal, DS.Spacing.sm)
                                }
                            }
                        }
                        .skinPlatter(skin)
                        .skinPlatterDepth(skin)

                        Button {
                            Haptics.tap()
                            tasks.append(TaskEntry())
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .buttonStyle(.action(role: .secondary, size: .compact))
                        .padding(.leading, DS.Spacing.md)

                        // Legend
                        pickerLegend
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.xl)
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)

            SkinSeparator()

            // Footer — right-aligned buttons like AddEventView
            HStack {
                Spacer()

                Button(action: onBack) {
                    Text("Cancel")
                }
                .buttonStyle(.action(role: .secondary))
                .keyboardShortcut(.cancelAction)

                Button {
                    Haptics.tap()
                    planTasks()
                } label: {
                    Label("Plan Tasks", systemImage: "wand.and.stars")
                }
                .buttonStyle(.action(role: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(validTasks.isEmpty || isOptimizing)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .frame(height: DS.Size.actionFooterHeight)
            .skinBarBackground(skin)
        }
    }

    // MARK: - Picker Legend

    private var pickerLegend: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            legendRow(icon: "clock", label: "Duration", description: "how long the task will take")
            legendRow(icon: "exclamationmark", label: "Priority", description: "Low / Med / High — affects scheduling order")
            legendRow(icon: "number", label: "Story Points", description: "effort estimate (Fibonacci: 1, 2, 3, 5, 8, 13)")
        }
        .padding(.top, DS.Spacing.sm)
        .padding(.leading, DS.Spacing.md)
    }

    private func legendRow(icon: String, label: String, description: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextTertiary)
                .frame(width: 14)
            Text("\(label)")
                .font(.caption2.bold())
                .foregroundStyle(skin.resolvedTextSecondary)
            Text("— \(description)")
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextTertiary)
        }
    }

    // MARK: - Task Row

    private func taskRow(task: Binding<TaskEntry>) -> some View {
        TaskRowCard(task: task, taskCount: tasks.count) {
            tasks.removeAll { $0.id == task.wrappedValue.id }
        }
    }

    // MARK: - Actions

    private func planTasks() {
        isOptimizing = true
        let eventSpecs = validTasks.map { task in
            EventSpec(
                title: task.title,
                minutes: task.minutes,
                priority: task.priority.value,
                energy: min(1.0, Double(task.minutes) / 180.0),
                storyPoints: task.storyPoints
            )
        }

        let recipe = ScheduleRecipe(
            id: "quick-add-tasks",
            name: "Quick Add Tasks",
            events: eventSpecs,
            horizon: horizon,
            speed: horizon == .week ? .balanced : .quick
        )

        Task {
            let result = await optimizerService.executeRecipe(
                recipe,
                reminderService: reminderService
            )
            isOptimizing = false
            if result.optimizerResult != nil {
                onShowResults?()
            }
        }
    }

    private func formatMinutes(_ m: Int) -> String {
        if m < 60 { return "\(m)m" }
        let h = m / 60
        let r = m % 60
        return r == 0 ? "\(h)h" : "\(h)h\(r)m"
    }
}

// MARK: - Task Row Card

private struct TaskRowCard: View {
    @Binding var task: QuickAddTasksView.TaskEntry
    let taskCount: Int
    let onRemove: () -> Void

    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            TextField("Task name", text: $task.title)
                .textFieldStyle(.plain)
                .font(.headline)
                .accessibilityLabel("Task name")

            Spacer()

            // Duration picker
            Menu {
                ForEach([15, 30, 45, 60, 90, 120, 180], id: \.self) { min in
                    Button(formatMinutes(min)) { task.minutes = min }
                }
            } label: {
                Text(formatMinutes(task.minutes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xxs)
                    .background(skin.accentColor.opacity(DS.Opacity.lightFill))
                    .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Duration: \(formatMinutes(task.minutes))")

            // Priority picker
            Menu {
                ForEach(QuickAddTasksView.TaskPriority.allCases, id: \.self) { p in
                    Button {
                        task.priority = p
                    } label: {
                        Label(p.rawValue, systemImage: p.icon)
                    }
                }
            } label: {
                Label {
                    Text(task.priority.rawValue)
                        .font(.caption)
                } icon: {
                    Image(systemName: task.priority.icon)
                        .font(.caption)
                }
                .foregroundStyle(task.priority == .high ? skin.accentColor : skin.resolvedTextSecondary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .background(skin.accentColor.opacity(DS.Opacity.lightFill))
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.leading, DS.Spacing.xs)
            .accessibilityLabel("Priority: \(task.priority.rawValue)")

            // Story points picker
            Menu {
                Button("—") { task.storyPoints = nil }
                ForEach(QuickAddTasksView.fibonacciPoints, id: \.self) { sp in
                    Button("\(sp) SP") { task.storyPoints = sp }
                }
            } label: {
                Text(task.storyPoints.map { "\($0) SP" } ?? "SP")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(task.storyPoints != nil ? skin.accentColor : skin.resolvedTextTertiary)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xxs)
                    .background(skin.accentColor.opacity(DS.Opacity.lightFill))
                    .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.leading, DS.Spacing.xs)
            .accessibilityLabel("Story points: \(task.storyPoints.map { "\($0)" } ?? "none")")

            // Remove button
            if taskCount > 1 {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .buttonStyle(.plain)
                .padding(.leading, DS.Spacing.xs)
                .accessibilityLabel("Remove task")
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
    }

    private func formatMinutes(_ m: Int) -> String {
        if m < 60 { return "\(m)m" }
        let h = m / 60
        let r = m % 60
        return r == 0 ? "\(h)h" : "\(h)h\(r)m"
    }
}
