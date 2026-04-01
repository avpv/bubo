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
    @State private var appliedScenarioIndex: Int? = nil
    @State private var isAnimatingSpinner = false

    private static let timeFormatter = DS.timeFormatter

    enum OptimizerAction: String, CaseIterable {
        case focusBlocks = "Focus Time"
        case planDay = "Plan Day"
        case pomodoro = "Pomodoro"

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

            if optimizerService.isOptimizing {
                optimizingView
            } else if !optimizerService.scenarios.isEmpty {
                scenarioResults
            } else {
                VStack(spacing: DS.Spacing.md) {
                    actionPicker
                    configurationView
                }
            }

            Spacer(minLength: 0)
            SkinSeparator()
            footerActions
        }
        .onChange(of: optimizerService.scenarios.count) { _, _ in
            // Reset selection when new results arrive
            selectedScenarioIndex = 0
            appliedScenarioIndex = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        PopoverHeader(
            title: "Schedule Assistant",
            showBack: true,
            onBack: onBack
        )
    }

    // MARK: - Action Picker

    private var actionPicker: some View {
        HStack {
            Text("Action")
                .font(.headline)
                .foregroundStyle(skin.resolvedTextPrimary)
                .accessibilityAddTraits(.isHeader)
            
            Spacer()
            
            Picker("Action", selection: $selectedAction) {
                ForEach(OptimizerAction.allCases, id: \.self) { action in
                    Text(action.rawValue).tag(action)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(.horizontal, DS.Spacing.md)
            .onChange(of: selectedAction) { _, _ in
                Haptics.tap()
                optimizerService.scenarios = []
                selectedScenarioIndex = 0
                appliedScenarioIndex = nil
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.lg)
    }

    // MARK: - Configuration

    private var configurationView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                switch selectedAction {
                case .focusBlocks:
                    focusBlockConfig
                case .planDay:
                    planDayConfig
                case .pomodoro:
                    pomodoroConfig
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
    }

    private var focusBlockConfig: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Settings")
                .font(.headline)
                .foregroundStyle(skin.resolvedTextPrimary)
                .accessibilityAddTraits(.isHeader)

            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.sm, verticalSpacing: DS.Spacing.md) {
                GridRow {
                    Text("Blocks")
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .gridColumnAlignment(.trailing)
                    
                    SegmentedPillPicker(
                        options: Array(1...4),
                        selection: $focusBlockCount,
                        labelProvider: { "\($0)" }
                    )
                }

                GridRow {
                    Text("Duration")
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .gridColumnAlignment(.trailing)
                    
                    SegmentedPillPicker(
                        options: [30, 60, 90, 120, 180],
                        selection: $focusBlockMinutes,
                        labelProvider: { minutes in
                            if minutes < 60 { return "\(minutes)m" }
                            let hours = minutes / 60
                            let rem = minutes % 60
                            if rem == 0 { return "\(hours)h" }
                            return "\(hours)h \(rem)m"
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.md)
            .skinPlatter(skin)
            .skinPlatterDepth(skin)
        }
    }

    private var planDayConfig: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Pending Events")
                .font(.headline)
                .foregroundStyle(skin.resolvedTextPrimary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                let localEvents = reminderService.localEvents.filter { $0.isUpcoming }
                if localEvents.isEmpty {
                    Text("No local events to optimize.")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextTertiary)
                } else {
                    Text("\(localEvents.count) event(s) will be automatically scheduled.")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextSecondary)

                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        ForEach(localEvents) { event in
                            HStack(spacing: DS.Spacing.sm) {
                                Circle()
                                    .fill(event.colorTag?.color ?? Color.accentColor)
                                    .frame(width: 8, height: 8)
                                Text(event.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                Text(event.formattedTimeRange)
                                    .font(.caption2)
                                    .foregroundStyle(skin.resolvedTextTertiary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.md)
            .skinPlatter(skin)
            .skinPlatterDepth(skin)
        }
    }

    private var pomodoroConfig: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Configuration")
                .font(.headline)
                .foregroundStyle(skin.resolvedTextPrimary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Bubo will analyze today's schedule and suggest an uninterrupted 25-minute gap for standard deep work.")
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.md)
            .skinPlatter(skin)
            .skinPlatterDepth(skin)
        }
    }

    // MARK: - Optimizing State

    private var optimizingView: some View {
        VStack(spacing: DS.Spacing.lg) {
            ZStack {
                Circle()
                    .strokeBorder(skin.accentColor.opacity(0.15), lineWidth: 4)
                    .frame(width: 48, height: 48)
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(skin.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 48, height: 48)
                    .rotationEffect(.degrees(isAnimatingSpinner ? 360 : 0))
                    .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: isAnimatingSpinner)
                    .onAppear { isAnimatingSpinner = true }
                    .onDisappear { isAnimatingSpinner = false }
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 20))
                    .foregroundStyle(skin.accentColor)
                    .symbolEffect(.pulse)
            }
            
            VStack(spacing: DS.Spacing.xs) {
                Text("Analyzing schedule...")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextPrimary)
                Text("Finding the perfect time slots based on your habits.")
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.lg)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
    }

    // MARK: - Results

    private var scenarioResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text("Found \(optimizerService.scenarios.count) scenario(s)")
                    .font(.subheadline.weight(.medium))

                // Scenario tabs
                if optimizerService.scenarios.count > 1 {
                    Picker("Scenario", selection: $selectedScenarioIndex) {
                        ForEach(0..<optimizerService.scenarios.count, id: \.self) { idx in
                            Text("Option \(idx + 1)").tag(idx)
                        }
                    }
                    .pickerStyle(.segmented)
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
            // Fitness score pill
            HStack {
                Label("Match: \(Int(max(0, scenario.fitness) * 100))%", systemImage: "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(skin.accentColor)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, 4)
                    .background(skin.accentColor.opacity(0.15))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(skin.accentColor.opacity(0.3), lineWidth: 1))
                Spacer()
            }
            .padding(.bottom, DS.Spacing.xs)

            // Events in this scenario
            ForEach(scenario.genes, id: \.eventId) { gene in
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: gene.isFocusBlock ? "brain.head.profile" : "calendar")
                        .font(.caption)
                        .foregroundStyle(skin.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(gene.title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(formatTimeRange(gene.startTime, gene.endTime))
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedTextTertiary)
                    }

                    Spacer()
                }
                .padding(DS.Spacing.sm)
                .background(skin.resolvedPlatterMaterial)
                .skinPlatterDepth(skin)
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
                        .foregroundStyle(skin.resolvedWarningColor)
                    ForEach(scenario.constraintViolations, id: \.self) { v in
                        Text("  \(v)")
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedWarningColor)
                    }
                }
            }

            // Action buttons
            HStack(spacing: DS.Spacing.sm) {
                // Apply
                let isApplied = appliedScenarioIndex == selectedScenarioIndex
                Button {
                    Haptics.tap()
                    optimizerService.applyScenario(
                        at: selectedScenarioIndex,
                        to: reminderService
                    )
                    appliedScenarioIndex = selectedScenarioIndex
                } label: {
                    Label(
                        isApplied ? "Applied" : "Apply this schedule",
                        systemImage: isApplied ? "checkmark.circle" : "checkmark.circle.fill"
                    )
                }
                .buttonStyle(.action(role: .primary, size: .flexible))
                .frame(maxWidth: .infinity)
                .disabled(isApplied)

                // Reject (sends feedback to preference learner)
                if appliedScenarioIndex == nil {
                    Button {
                        Haptics.tap()
                        optimizerService.rejectScenario(at: selectedScenarioIndex)
                    } label: {
                        Image(systemName: "hand.thumbsdown")
                            .padding(.vertical, DS.Spacing.sm)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .accessibilityLabel("Reject this schedule")
                    .help("Reject this schedule")
                }
            }
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
                        RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius)
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
            Button(action: {
                Haptics.tap()
                if !optimizerService.scenarios.isEmpty {
                    if appliedScenarioIndex == nil {
                        for i in 0..<optimizerService.scenarios.count {
                            optimizerService.rejectScenario(at: i)
                        }
                    }
                    optimizerService.scenarios = [] // clear scenarios
                    selectedScenarioIndex = 0
                    appliedScenarioIndex = nil
                } else {
                    onBack() // cancel
                }
            }) {
                Text(!optimizerService.scenarios.isEmpty ? "Clear" : "Cancel")
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.action(role: .secondary))

            Spacer()

            if optimizerService.scenarios.isEmpty {
                Button(action: {
                    Haptics.tap()
                    let action = selectedAction
                    let events = reminderService.localEvents.filter { $0.isUpcoming }
                    Task {
                        switch action {
                        case .focusBlocks:
                            await optimizerService.suggestFocusBlocks(count: focusBlockCount, durationMinutes: focusBlockMinutes, reminderService: reminderService)
                        case .planDay:
                            let tasks = events.map { $0.toOptimizableEvent() }
                            await optimizerService.optimizeDay(reminderService: reminderService, movableTasks: tasks)
                        case .pomodoro:
                            await optimizerService.suggestPomodoroSlot(config: .classic, reminderService: reminderService)
                        }
                    }
                }) {
                    Label(
                        selectedAction == .focusBlocks ? "Find Focus Slots" : (selectedAction == .planDay ? "Arrange My Day" : "Find 25m Slot"),
                        systemImage: "wand.and.stars"
                    )
                }
                .buttonStyle(.action(role: .primary))
                .disabled(optimizerService.isOptimizing || (selectedAction == .planDay && reminderService.localEvents.filter { $0.isUpcoming }.isEmpty))
            } else {
                let isApplied = appliedScenarioIndex == selectedScenarioIndex
                Button(action: {
                    Haptics.tap()
                    optimizerService.applyScenario(at: selectedScenarioIndex, to: reminderService)
                    appliedScenarioIndex = selectedScenarioIndex
                }) {
                    Label(isApplied ? "Applied" : "Apply Schedule", systemImage: isApplied ? "checkmark.circle" : "checkmark.circle.fill")
                }
                .buttonStyle(.action(role: .primary))
                .disabled(isApplied)
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .frame(height: DS.Size.actionFooterHeight)
        .skinBarBackground(skin)
    }

    // MARK: - Helpers

    private func formatTimeRange(_ start: Date, _ end: Date) -> String {
        "\(Self.timeFormatter.string(from: start)) – \(Self.timeFormatter.string(from: end))"
    }
}

// MARK: - Components

struct SegmentedPillPicker<T: Equatable & Hashable>: View {
    @Environment(\.activeSkin) private var skin
    let options: [T]
    @Binding var selection: T
    let labelProvider: (T) -> String

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    Haptics.tap()
                    withAnimation(skin.resolvedMicroAnimation) {
                        selection = option
                    }
                } label: {
                    Text(labelProvider(option))
                        .font(.caption.weight(isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? skin.resolvedTextPrimary : skin.resolvedTextSecondary)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(skin.accentColor.opacity(0.15))
                            }
                        }
                        .overlay {
                            if isSelected {
                                Capsule()
                                    .strokeBorder(skin.accentColor.opacity(0.4), lineWidth: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}


