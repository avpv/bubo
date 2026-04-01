import SwiftUI

// MARK: - Schedule Assistant View

/// Single-form schedule optimization panel shown in the MenuBarView popover.
struct OptimizerView: View {
    @Environment(\.activeSkin) private var skin
    @Environment(\.openSettings) private var openSettings
    var optimizerService: OptimizerService
    var reminderService: ReminderService
    var onBack: () -> Void

    // MARK: - Goals (checkboxes)
    @State private var wantsFocusBlocks = true
    @State private var wantsPomodoroSlot = false
    @State private var wantsRearrange = false

    // MARK: - Event identity
    @State private var eventTitle = ""
    @State private var selectedColorTag: EventColorTag? = .blue
    @FocusState private var isTitleFocused: Bool

    // MARK: - Focus block params
    @State private var focusBlockCount = 2
    @State private var focusBlockMinutes = 120

    // MARK: - Results
    @State private var selectedScenarioIndex = 0
    @State private var appliedScenarioIndex: Int? = nil
    @State private var isAnimatingSpinner = false

    private static let timeFormatter = DS.timeFormatter

    private var hasAnyGoal: Bool {
        wantsFocusBlocks || wantsPomodoroSlot || wantsRearrange
    }

    private var localEvents: [CalendarEvent] {
        reminderService.localEvents.filter { $0.isUpcoming }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

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
        .onChange(of: optimizerService.scenarios.count) { _, _ in
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

    // MARK: - Configuration (single form)

    private var configurationView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                workingHoursSection
                eventIdentitySection
                goalsSection
                settingsLink
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Working Hours (inline from settings)

    private var workingHoursSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Working Hours")
                .font(.headline)
                .foregroundStyle(skin.resolvedTextPrimary)
                .accessibilityAddTraits(.isHeader)

            HStack {
                Text("\(optimizerService.workingHoursStart):00")
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(skin.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))

                Text("–")
                    .foregroundStyle(skin.resolvedTextTertiary)

                Text("\(optimizerService.workingHoursEnd):00")
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(skin.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.md)
            .skinPlatter(skin)
            .skinPlatterDepth(skin)
        }
    }

    // MARK: Event identity (title + color)

    private var skinAccent: Color {
        skin.isClassic ? DS.Colors.accent : skin.accentColor
    }

    private var eventIdentitySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Event")
                .font(.headline)
                .foregroundStyle(skin.resolvedTextPrimary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                TextField("Title", text: $eventTitle, prompt: Text("Event title (e.g. Deep Work)").foregroundStyle(skin.resolvedTextSecondary))
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused($isTitleFocused)

                SkinSeparator()

                HStack(spacing: DS.Spacing.xs) {
                    ForEach(EventColorTag.allCases, id: \.self) { tag in
                        Button {
                            Haptics.tap()
                            selectedColorTag = selectedColorTag == tag ? nil : tag
                        } label: {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            skin.resolvedTextPrimary.opacity(selectedColorTag == tag ? 0.8 : 0),
                                            lineWidth: selectedColorTag == tag ? 2 : 0
                                        )
                                )
                                .shadow(
                                    color: selectedColorTag == tag ? tag.color.opacity(DS.Opacity.half) : .clear,
                                    radius: selectedColorTag == tag ? 3 : 0
                                )
                                .scaleEffect(selectedColorTag == tag ? 1.1 : 1.0)
                                .animation(skin.resolvedMicroAnimation, value: selectedColorTag)
                                .padding(DS.Spacing.xs)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(tag.rawValue)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.md)
            .skinPlatter(skin)
            .skinPlatterDepth(skin)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                    .stroke(isTitleFocused ? skinAccent.opacity(DS.Opacity.overlayDark) : Color.clear, lineWidth: DS.Size.focusRingWidth)
                    .shadow(color: isTitleFocused ? skinAccent.opacity(0.4) : .clear, radius: 4)
            )
            .animation(skin.resolvedMicroAnimation, value: isTitleFocused)
        }
    }

    // MARK: Goals (checkboxes)

    private var goalsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("What to schedule")
                .font(.headline)
                .foregroundStyle(skin.resolvedTextPrimary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                // Focus Blocks
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Toggle(isOn: $wantsFocusBlocks) {
                        Label("Focus blocks", systemImage: "brain.head.profile")
                    }

                    if wantsFocusBlocks {
                        Grid(alignment: .leading, horizontalSpacing: DS.Spacing.sm, verticalSpacing: DS.Spacing.sm) {
                            GridRow {
                                Text("Count")
                                    .font(.caption)
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
                                    .font(.caption)
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
                        .padding(.leading, DS.Spacing.xl)
                    }
                }

                SkinSeparator()

                // Pomodoro
                Toggle(isOn: $wantsPomodoroSlot) {
                    Label("Pomodoro slot (25 min)", systemImage: "timer")
                }

                SkinSeparator()

                // Rearrange local events
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Toggle(isOn: $wantsRearrange) {
                        Label("Rearrange local events", systemImage: "calendar.day.timeline.left")
                    }

                    if wantsRearrange && localEvents.isEmpty {
                        Text("No local events to optimize.")
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextTertiary)
                            .padding(.leading, DS.Spacing.xl)
                    } else if wantsRearrange {
                        Text("\(localEvents.count) event(s) will be rearranged")
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextSecondary)
                            .padding(.leading, DS.Spacing.xl)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.md)
            .skinPlatter(skin)
            .skinPlatterDepth(skin)
        }
    }

    // MARK: Settings link

    private var settingsLink: some View {
        Button {
            Haptics.tap()
            SettingsViewModel.pendingPane = .optimizer
            openSettings()
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "gearshape")
                    .font(.caption)
                Text("Advanced settings")
                    .font(.caption)
            }
            .foregroundStyle(skin.resolvedTextSecondary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .trailing)
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
                Text("Optimizing schedule…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextPrimary)
                Text("Searching for optimal time slots…")
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

                if optimizerService.scenarios.count > 1 {
                    Picker("Scenario", selection: $selectedScenarioIndex) {
                        ForEach(0..<optimizerService.scenarios.count, id: \.self) { idx in
                            Text("Option \(idx + 1)").tag(idx)
                        }
                    }
                    .pickerStyle(.segmented)
                }

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

            if !scenario.objectiveBreakdown.isEmpty {
                objectiveBreakdownView(scenario.objectiveBreakdown)
            }

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
                    optimizerService.scenarios = []
                    selectedScenarioIndex = 0
                    appliedScenarioIndex = nil
                } else {
                    onBack()
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
                    runOptimization()
                }) {
                    Label("Optimize", systemImage: "wand.and.stars")
                }
                .buttonStyle(.action(role: .primary))
                .disabled(optimizerService.isOptimizing || !hasAnyGoal || (wantsRearrange && localEvents.isEmpty && !wantsFocusBlocks && !wantsPomodoroSlot))
            } else {
                let isApplied = appliedScenarioIndex == selectedScenarioIndex
                Button(action: {
                    Haptics.tap()
                    optimizerService.applyScenario(
                        at: selectedScenarioIndex,
                        to: reminderService,
                        titleOverride: eventTitle.isEmpty ? nil : eventTitle,
                        colorOverride: selectedColorTag
                    )
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

    // MARK: - Actions

    private func runOptimization() {
        Task {
            // Run focus blocks if requested
            if wantsFocusBlocks {
                await optimizerService.suggestFocusBlocks(
                    count: focusBlockCount,
                    durationMinutes: focusBlockMinutes,
                    reminderService: reminderService
                )
            }
            // Run pomodoro if requested (and focus blocks wasn't the only goal)
            if wantsPomodoroSlot && !wantsFocusBlocks {
                await optimizerService.suggestPomodoroSlot(
                    config: .classic,
                    reminderService: reminderService
                )
            }
            // Run day planning if requested (and nothing else was the only goal)
            if wantsRearrange && !localEvents.isEmpty {
                let tasks = localEvents.map { $0.toOptimizableEvent() }
                await optimizerService.optimizeDay(
                    reminderService: reminderService,
                    movableTasks: tasks
                )
            }
        }
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
