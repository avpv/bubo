import SwiftUI

// MARK: - Optimizer View

/// Main optimizer panel shown in the MenuBarView popover.
struct OptimizerView: View {
    @Environment(\.activeSkin) private var skin
    var optimizerService: OptimizerService
    var reminderService: ReminderService
    var onBack: () -> Void

    @State private var selectedAction: OptimizerAction = .focusBlocks
    @State private var focusBlockCount = 2
    @State private var focusBlockMinutes = 120
    @State private var selectedScenarioIndex = 0

    enum OptimizerAction: String, CaseIterable {
        case focusBlocks = "Focus Blocks"
        case planDay = "Plan Day"
        case pomodoro = "Pomodoro Slot"

        var icon: String {
            switch self {
            case .focusBlocks: "brain.head.profile"
            case .planDay: "calendar.day.timeline.left"
            case .pomodoro: "timer"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SkinSeparator()
            actionPicker
            SkinSeparator()

            if optimizerService.isOptimizing {
                optimizingView
            } else if !optimizerService.scenarios.isEmpty {
                scenarioResults
            } else {
                configurationView
            }

            Spacer(minLength: 0)
            SkinSeparator()
            footerActions
        }
    }

    // MARK: - Header

    private var header: some View {
        PopoverHeader(
            title: "Optimizer",
            leading: AnyView(
                Button {
                    Haptics.tap()
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: DS.Size.iconSmall, weight: .semibold))
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
                .buttonStyle(.borderless)
            )
        )
    }

    // MARK: - Action Picker

    private var actionPicker: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(OptimizerAction.allCases, id: \.self) { action in
                Button {
                    Haptics.tap()
                    withAnimation(DS.Animation.smoothSpring) {
                        selectedAction = action
                        optimizerService.scenarios = []
                    }
                } label: {
                    Label(action.rawValue, systemImage: action.icon)
                        .font(.caption)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xs)
                        .background(
                            selectedAction == action
                                ? skin.accentColor.opacity(0.2)
                                : Color.clear
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
    }

    // MARK: - Configuration

    private var configurationView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                switch selectedAction {
                case .focusBlocks:
                    focusBlockConfig
                case .planDay:
                    planDayConfig
                case .pomodoro:
                    pomodoroConfig
                }
            }
            .padding(DS.Spacing.md)
        }
    }

    private var focusBlockConfig: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text("Find optimal time for focus blocks in today's schedule.")
                .font(.caption)
                .foregroundStyle(skin.resolvedTextSecondary)

            HStack {
                Text("Blocks:")
                    .font(.subheadline)
                Picker("", selection: $focusBlockCount) {
                    ForEach(1...4, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .frame(width: 60)
            }

            HStack {
                Text("Duration:")
                    .font(.subheadline)
                Picker("", selection: $focusBlockMinutes) {
                    Text("30 min").tag(30)
                    Text("60 min").tag(60)
                    Text("90 min").tag(90)
                    Text("2 hours").tag(120)
                    Text("3 hours").tag(180)
                }
                .frame(width: 100)
            }

            optimizeButton {
                optimizerService.suggestFocusBlocks(
                    count: focusBlockCount,
                    durationMinutes: focusBlockMinutes,
                    reminderService: reminderService
                )
            }
        }
    }

    private var planDayConfig: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text("Optimize placement of your local events for today.")
                .font(.caption)
                .foregroundStyle(skin.resolvedTextSecondary)

            let localEvents = reminderService.localEvents.filter { $0.isUpcoming }
            if localEvents.isEmpty {
                Text("No local events to optimize.")
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextTertiary)
            } else {
                Text("\(localEvents.count) event(s) to place")
                    .font(.subheadline)

                ForEach(localEvents) { event in
                    HStack(spacing: DS.Spacing.sm) {
                        Circle()
                            .fill(event.colorTag?.color ?? Color.accentColor)
                            .frame(width: 8, height: 8)
                        Text(event.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(event.formattedTimeRange)
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedTextTertiary)
                    }
                }

                optimizeButton {
                    let tasks = localEvents.map { $0.toOptimizableEvent() }
                    optimizerService.optimizeDay(
                        reminderService: reminderService,
                        movableTasks: tasks
                    )
                }
            }
        }
    }

    private var pomodoroConfig: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text("Find the best time for a Pomodoro session.")
                .font(.caption)
                .foregroundStyle(skin.resolvedTextSecondary)

            optimizeButton {
                optimizerService.suggestPomodoroSlot(
                    config: .classic,
                    reminderService: reminderService
                )
            }
        }
    }

    private func optimizeButton(action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Label("Optimize", systemImage: "wand.and.stars")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.sm)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }

    // MARK: - Optimizing State

    private var optimizingView: some View {
        VStack(spacing: DS.Spacing.lg) {
            ProgressView()
            Text("Optimizing your schedule...")
                .font(.subheadline)
                .foregroundStyle(skin.resolvedTextSecondary)
            if let progress = optimizerService.optimizer.progress {
                Text("Generation \(progress.generation) | Best: \(String(format: "%.2f", progress.bestFitness))")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results

    private var scenarioResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text("Found \(optimizerService.scenarios.count) scenario(s)")
                    .font(.subheadline.weight(.medium))

                // Scenario tabs
                if optimizerService.scenarios.count > 1 {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(0..<optimizerService.scenarios.count, id: \.self) { idx in
                            Button {
                                Haptics.tap()
                                withAnimation(DS.Animation.smoothSpring) {
                                    selectedScenarioIndex = idx
                                }
                            } label: {
                                Text("Option \(idx + 1)")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, DS.Spacing.sm)
                                    .padding(.vertical, DS.Spacing.xs)
                                    .background(
                                        selectedScenarioIndex == idx
                                            ? skin.accentColor.opacity(0.2)
                                            : Color.clear
                                    )
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Selected scenario details
                if selectedScenarioIndex < optimizerService.scenarios.count {
                    let scenario = optimizerService.scenarios[selectedScenarioIndex]
                    scenarioDetail(scenario)
                }
            }
            .padding(DS.Spacing.md)
        }
    }

    private func scenarioDetail(_ scenario: ScheduleScenario) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Fitness score
            HStack {
                Text("Score:")
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextSecondary)
                Text(String(format: "%.1f%%", max(0, scenario.fitness) * 100))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(skin.accentColor)
            }

            // Events in this scenario
            ForEach(scenario.genes, id: \.eventId) { gene in
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: gene.isFocusBlock ? "brain.head.profile" : "calendar")
                        .font(.caption)
                        .foregroundStyle(skin.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(gene.eventId)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)

                        Text(formatTimeRange(gene.startTime, gene.endTime))
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedTextTertiary)
                    }

                    Spacer()
                }
                .padding(DS.Spacing.sm)
                .skinPlatter(skin)
            }

            // Objective breakdown
            if !scenario.objectiveBreakdown.isEmpty {
                objectiveBreakdownView(scenario.objectiveBreakdown)
            }

            // Violations
            if !scenario.constraintViolations.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Warnings:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DS.Colors.warning)
                    ForEach(scenario.constraintViolations, id: \.self) { v in
                        Text("  \(v)")
                            .font(.caption2)
                            .foregroundStyle(DS.Colors.warning)
                    }
                }
            }

            // Accept button
            Button {
                Haptics.tap()
                optimizerService.applyScenario(
                    at: selectedScenarioIndex,
                    to: reminderService
                )
            } label: {
                Label("Apply this schedule", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.sm)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, DS.Spacing.sm)
        }
    }

    private func objectiveBreakdownView(_ breakdown: [String: Double]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Breakdown:")
                .font(.caption.weight(.medium))
                .foregroundStyle(skin.resolvedTextSecondary)

            ForEach(breakdown.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                HStack(spacing: DS.Spacing.sm) {
                    Text(key)
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .frame(width: 80, alignment: .leading)

                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(skin.accentColor.opacity(0.3))
                            .frame(width: geo.size.width * max(0, min(1, value)))
                    }
                    .frame(height: 6)

                    Text(String(format: "%.0f%%", value * 100))
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack {
            if !optimizerService.scenarios.isEmpty {
                Button {
                    Haptics.tap()
                    optimizerService.scenarios = []
                } label: {
                    Label("New", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            if let date = optimizerService.lastOptimizationDate {
                Text("Last: \(date, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, DS.Spacing.lg)
        .frame(maxWidth: .infinity)
        .frame(height: DS.Size.actionFooterHeight)
        .skinBarBackground(skin)
    }

    // MARK: - Helpers

    private func formatTimeRange(_ start: Date, _ end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }
}
