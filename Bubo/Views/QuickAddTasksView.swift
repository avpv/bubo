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
    @State private var sequentialOrder = false
    @State private var inlineResult: InlineResult? = nil

    enum InlineResult: Equatable {
        case success([ScheduleScenario])
        case error(String)

        static func == (lhs: InlineResult, rhs: InlineResult) -> Bool {
            switch (lhs, rhs) {
            case (.success(let a), .success(let b)):
                return a.map(\.fitness) == b.map(\.fitness)
            case (.error(let a), .error(let b)):
                return a == b
            default: return false
            }
        }
    }

    struct TaskEntry: Identifiable {
        let id = UUID()
        var title: String = ""
        var minutes: Int = 60
        var priority: TaskPriority = .medium
        var storyPoints: Int? = nil
        var deadline: Date? = nil
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

        /// Default story points inferred from priority when user doesn't set SP explicitly.
        var defaultStoryPoints: Int {
            switch self {
            case .low: return 2
            case .medium: return 5
            case .high: return 8
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

                    // Sequential order toggle
                    Toggle(isOn: $sequentialOrder) {
                        Label("Sequential order", systemImage: "arrow.down.line")
                            .font(.subheadline)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(skin.accentColor)
                    .staggeredEntrance(index: 1)

                    // Tasks section
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Tasks")
                            .font(.headline)
                            .foregroundStyle(skin.resolvedTextPrimary)
                            .accessibilityAddTraits(.isHeader)

                        VStack(spacing: 0) {
                            ForEach(Array($tasks.enumerated()), id: \.element.id) { index, $task in
                                HStack(spacing: 0) {
                                    if sequentialOrder {
                                        Text("\(index + 1)")
                                            .font(.caption2.bold().monospacedDigit())
                                            .foregroundStyle(skin.resolvedTextTertiary)
                                            .frame(width: 20)
                                    }
                                    taskRow(task: $task)
                                }
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

                    }

                    // Inline results — shown right below tasks after optimization
                    if let result = inlineResult {
                        inlineResultSection(result)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.xl)
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)
            .animation(skin.resolvedMicroAnimation, value: inlineResult != nil)

            SkinSeparator()

            // Footer adapts to result state
            HStack {
                Spacer()

                if case .success = inlineResult {
                    Button {
                        withAnimation(skin.resolvedMicroAnimation) {
                            inlineResult = nil
                        }
                    } label: {
                        Text("Back")
                    }
                    .buttonStyle(.action(role: .secondary))
                    .keyboardShortcut(.cancelAction)

                    Button {
                        Haptics.impact()
                        optimizerService.applyRecipeScenario(at: 0, to: reminderService)
                        onBack()
                    } label: {
                        Label("Apply Schedule", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.action(role: .primary))
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(action: onBack) {
                        Text("Cancel")
                    }
                    .buttonStyle(.action(role: .secondary))
                    .keyboardShortcut(.cancelAction)

                    Button {
                        Haptics.tap()
                        planTasks()
                    } label: {
                        HStack(spacing: DS.Spacing.xs) {
                            if isOptimizing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "wand.and.stars")
                            }
                            Text(isOptimizing ? "Planning…" : "Plan Tasks")
                        }
                    }
                    .buttonStyle(.action(role: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(validTasks.isEmpty || isOptimizing)
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .frame(height: DS.Size.actionFooterHeight)
            .skinBarBackground(skin)
        }
    }

    // MARK: - Inline Results

    @ViewBuilder
    private func inlineResultSection(_ result: InlineResult) -> some View {
        switch result {
        case .success(let scenarios):
            if let scenario = scenarios.first {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedSuccessColor)
                        Text("Schedule ready")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(skin.resolvedSuccessColor)
                    }

                    ForEach(scenario.genes, id: \.eventId) { gene in
                        HStack(spacing: DS.Spacing.sm) {
                            Image(systemName: gene.isFocusBlock ? "brain.head.profile" : "calendar")
                                .font(.system(size: DS.Size.iconSmall))
                                .foregroundStyle(gene.isFocusBlock ? skin.accentColor : skin.resolvedTextTertiary)
                                .frame(width: DS.Size.iconMedium)

                            Text(gene.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(skin.resolvedTextPrimary)
                                .lineLimit(1)

                            Spacer()

                            Text("\(DS.timeFormatter.string(from: gene.startTime))\u{2009}\u{2013}\u{2009}\(DS.timeFormatter.string(from: gene.endTime))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(skin.resolvedTextSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.md)
                .skinPlatter(skin)
                .skinPlatterDepth(skin)
            }

        case .error(let message):
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedWarningColor)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DS.Size.cornerRadius)
                    .fill(skin.resolvedWarningColor.opacity(0.08))
            )
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

        // Assign stable IDs so dependencies can reference them
        let taskIds = validTasks.map { _ in UUID().uuidString }

        let eventSpecs = validTasks.enumerated().map { index, task in
            let sp = task.storyPoints ?? task.priority.defaultStoryPoints
            let deps: [String] = sequentialOrder && index > 0 ? [taskIds[index - 1]] : []
            return EventSpec(
                specId: taskIds[index],
                title: task.title,
                minutes: task.minutes,
                priority: task.priority.value,
                energy: min(1.0, Double(task.minutes) / 180.0),
                storyPoints: sp,
                deadline: task.deadline,
                dependsOn: deps
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
            switch result {
            case .success(let r):
                withAnimation(skin.resolvedMicroAnimation) {
                    inlineResult = .success(r.scenarios)
                }
                Haptics.impact()
            case .partialSuccess(let r, let warnings):
                if r.scenarios.isEmpty {
                    withAnimation(skin.resolvedMicroAnimation) {
                        inlineResult = .error(warnings.first ?? "Could not plan tasks")
                    }
                } else {
                    withAnimation(skin.resolvedMicroAnimation) {
                        inlineResult = .success(r.scenarios)
                    }
                    Haptics.impact()
                }
            case .noEventsToOptimize:
                withAnimation(skin.resolvedMicroAnimation) {
                    inlineResult = .error("No tasks to plan")
                }
            case .infeasible(let reason, _):
                withAnimation(skin.resolvedMicroAnimation) {
                    inlineResult = .error(reason)
                }
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

            // Deadline picker
            Menu {
                Button("No deadline") { task.deadline = nil }
                Button("Today") { task.deadline = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86399) }
                Button("Tomorrow") { task.deadline = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400 + 86399) }
                Button("This week") { task.deadline = endOfWeek() }
                Button("Next week") { task.deadline = endOfWeek()?.addingTimeInterval(7 * 86400) }
            } label: {
                Label {
                    Text(deadlineLabel(task.deadline))
                        .font(.caption)
                } icon: {
                    Image(systemName: "calendar.badge.clock")
                        .font(.caption)
                }
                .foregroundStyle(deadlineColor(task.deadline))
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .background(skin.accentColor.opacity(DS.Opacity.lightFill))
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.leading, DS.Spacing.xs)
            .accessibilityLabel("Deadline: \(deadlineLabel(task.deadline))")

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

    private func deadlineLabel(_ date: Date?) -> String {
        guard let date else { return "Due" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    private func deadlineColor(_ date: Date?) -> Color {
        guard let date else { return skin.resolvedTextTertiary }
        if date < Date() { return skin.resolvedDestructiveColor }
        return skin.accentColor
    }

    private func endOfWeek() -> Date? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let daysUntilSunday = (8 - weekday) % 7
        return cal.date(byAdding: .day, value: max(1, daysUntilSunday), to: today)?
            .addingTimeInterval(86399)
    }
}
