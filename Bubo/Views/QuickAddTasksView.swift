import SwiftUI

// MARK: - Quick Add Tasks View

/// Batch entry of multiple tasks, then optimize them all at once.
struct QuickAddTasksView: View {
    @Environment(\.activeSkin) private var skin
    var optimizerService: OptimizerService
    var reminderService: ReminderService
    var onBack: () -> Void

    @State private var tasks: [TaskEntry] = [TaskEntry()]
    @State private var horizon: Horizon = .today
    @State private var isOptimizing = false
    @State private var result: RecipeResult? = nil

    struct TaskEntry: Identifiable {
        let id = UUID()
        var title: String = ""
        var minutes: Int = 60
        var priority: TaskPriority = .medium
    }

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
                    // Task entries
                    VStack(spacing: DS.Spacing.sm) {
                        ForEach($tasks) { $task in
                            taskRow(task: $task)
                        }

                        Button {
                            Haptics.tap()
                            tasks.append(TaskEntry())
                        } label: {
                            Label("Add task", systemImage: "plus")
                                .font(.caption)
                                .foregroundStyle(skin.accentColor)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, DS.Spacing.sm)
                    }

                    // Horizon picker
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Plan for")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(skin.resolvedTextSecondary)

                        Picker("", selection: $horizon) {
                            Text("Today").tag(Horizon.today)
                            Text("This Week").tag(Horizon.week)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.xl)
            }
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)
            SkinSeparator()

            // Footer
            HStack {
                Button(action: onBack) {
                    Text("Cancel")
                }
                .buttonStyle(.action(role: .secondary))
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    Haptics.tap()
                    planTasks()
                } label: {
                    Label("Plan Tasks", systemImage: "wand.and.stars")
                }
                .buttonStyle(.action(role: .primary))
                .disabled(validTasks.isEmpty || isOptimizing)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .frame(height: DS.Size.actionFooterHeight)
            .skinBarBackground(skin)
        }
    }

    // MARK: - Task Row

    private func taskRow(task: Binding<TaskEntry>) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            TextField("Task name", text: task.title)
                .textFieldStyle(.plain)
                .font(.caption)

            // Duration picker
            Menu {
                ForEach([15, 30, 45, 60, 90, 120, 180], id: \.self) { min in
                    Button(formatMinutes(min)) { task.minutes.wrappedValue = min }
                }
            } label: {
                Text(formatMinutes(task.wrappedValue.minutes))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .padding(.horizontal, DS.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(skin.accentColor.opacity(0.08))
                    .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Priority picker
            Menu {
                ForEach(TaskPriority.allCases, id: \.self) { p in
                    Button {
                        task.priority.wrappedValue = p
                    } label: {
                        Label(p.rawValue, systemImage: p.icon)
                    }
                }
            } label: {
                Image(systemName: task.wrappedValue.priority.icon)
                    .font(.caption2)
                    .foregroundStyle(task.wrappedValue.priority == .high ? skin.accentColor : skin.resolvedTextTertiary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Remove button
            if tasks.count > 1 {
                Button {
                    tasks.removeAll { $0.id == task.wrappedValue.id }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Spacing.sm)
        .skinPlatter(skin)
        .skinPlatterDepth(skin)
    }

    // MARK: - Actions

    private func planTasks() {
        isOptimizing = true
        let eventSpecs = validTasks.map { task in
            EventSpec(
                title: task.title,
                minutes: task.minutes,
                priority: task.priority.value,
                energy: min(1.0, Double(task.minutes) / 180.0)
            )
        }

        let recipe = ScheduleRecipe(
            id: "quick-add-tasks",
            name: "Quick Add Tasks",
            icon: "list.bullet",
            events: eventSpecs,
            horizon: horizon,
            speed: horizon == .week ? .balanced : .quick
        )

        Task {
            _ = await optimizerService.executeRecipe(
                recipe,
                reminderService: reminderService
            )
            isOptimizing = false
        }
    }

    private func formatMinutes(_ m: Int) -> String {
        if m < 60 { return "\(m)m" }
        let h = m / 60
        let r = m % 60
        return r == 0 ? "\(h)h" : "\(h)h\(r)m"
    }
}
