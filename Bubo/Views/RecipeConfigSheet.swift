import SwiftUI

// MARK: - Optimization State

private enum OptimizationState: Equatable {
    case idle
    case optimizing
    case success([ScheduleScenario])
    case error(String)

    static func == (lhs: OptimizationState, rhs: OptimizationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.optimizing, .optimizing): return true
        case (.success(let a), .success(let b)):
            return a.map(\.fitness) == b.map(\.fitness)
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Recipe Config Sheet

/// Generic configuration sheet that auto-renders UI controls
/// based on the recipe's `params` array.
/// One View for all recipes — zero per-recipe UI code.
struct RecipeConfigSheet: View {
    @Environment(\.activeSkin) private var skin
    let recipe: ScheduleRecipe
    var reminderService: ReminderService? = nil
    let onExecute: (ScheduleRecipe, [String: Any]) -> Void
    let onCancel: () -> Void
    var onAddTasks: (() -> Void)? = nil
    var onSwitchRecipe: ((ScheduleRecipe) -> Void)? = nil
    var optimizerService: OptimizerService? = nil
    var onDone: (() -> Void)? = nil

    @State private var paramValues: [String: Any] = [:]
    @State private var selectedEventIds: Set<String> = []
    @State private var optimizationState: OptimizationState = .idle

    /// Whether the recipe requires events but none are available.
    private var isBlockedByNoEvents: Bool {
        recipe.needsExistingEvents && localEventsForPicker.isEmpty
    }

    /// Whether the action button should be enabled.
    private var canExecute: Bool {
        if isBlockedByNoEvents { return false }
        if case .optimizing = optimizationState { return false }
        // If there's an eventMultiPicker param, at least one event must be selected
        if recipe.params.contains(where: { $0.kind == .eventMultiPicker }) {
            return !selectedEventIds.isEmpty
        }
        return true
    }

    /// Recipes that create new events (don't require existing tasks).
    private var suggestedAlternatives: [ScheduleRecipe] {
        RecipeCatalog.quickActions.filter { $0.isCreative }
    }

    private var actionButtonLabel: String {
        switch optimizationState {
        case .idle: return recipe.actionLabel
        case .optimizing: return "Optimizing..."
        case .success: return "Re-optimize"
        case .error: return "Retry"
        }
    }

    private var actionButtonIcon: String {
        switch optimizationState {
        case .success, .error: return "arrow.clockwise"
        default: return recipe.isCreative ? "calendar.badge.plus" : "wand.and.stars"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isBlockedByNoEvents {
                blockedEmptyState
            } else {
                normalConfigFlow
            }

            // Footer
            SkinSeparator()
            footer
        }
        .onAppear {
            initializeDefaults()
            // Auto-run for paramless recipes (1-click actions)
            if recipe.params.isEmpty && optimizerService != nil {
                executeOptimization()
            }
        }
    }

    // MARK: - Normal Config Flow

    private var normalConfigFlow: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
                // Header
                recipeHeader

                // Parameters — grouped in one section
                if !recipe.params.isEmpty {
                    settingsSection
                }

                // Preview for creative recipes
                if recipe.isCreative && !recipe.events.isEmpty {
                    creativePreviewSection
                }

                // Inline optimization results
                optimizationResultsSection
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.top, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.md)
        }
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Recipe Header

    private var recipeHeader: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: recipe.icon)
                .font(.title3)
                .foregroundStyle(skin.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name)
                    .font(.headline)
                    .foregroundStyle(skin.resolvedTextPrimary)
                Text(recipe.description)
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.md)
        .skinPlatter(skin)
        .skinPlatterDepth(skin)
    }

    // MARK: - Creative Preview Section

    private var creativePreviewSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Preview")
                .font(.headline)
                .foregroundStyle(skin.resolvedTextPrimary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                // Bar visualization
                previewTimeline

                // Event breakdown
                ForEach(Array(recipe.events.enumerated()), id: \.offset) { _, spec in
                    let minutes = resolvedMinutes(for: spec)
                    HStack(spacing: DS.Spacing.sm) {
                        Circle()
                            .fill(skin.accentColor)
                            .frame(width: 6, height: 6)
                        Text(spec.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(skin.resolvedTextPrimary)
                        Spacer()
                        Text(formatDuration(minutes * spec.count))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(skin.resolvedTextSecondary)
                    }
                }

                // Total time
                HStack {
                    Label(
                        "Total: \(formatDuration(totalCreativeMinutes))",
                        systemImage: "clock"
                    )
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextSecondary)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.md)
            .skinPlatter(skin)
            .skinPlatterDepth(skin)
        }
    }

    private var previewTimeline: some View {
        let segments = recipe.events.flatMap { spec -> [(title: String, minutes: Int)] in
            let mins = resolvedMinutes(for: spec)
            return (0..<spec.count).map { _ in (title: spec.title, minutes: mins) }
        }
        let total = max(segments.reduce(0) { $0 + $1.minutes }, 1)

        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    let fraction = CGFloat(segment.minutes) / CGFloat(total)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(skin.accentColor.opacity(index % 2 == 0 ? 0.7 : 0.4))
                        .frame(width: max(fraction * geo.size.width - 1, 4))
                        .overlay(
                            Group {
                                if fraction * geo.size.width > 30 {
                                    Text("\(segment.minutes)m")
                                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.white)
                                }
                            }
                        )
                }
            }
        }
        .frame(height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var totalCreativeMinutes: Int {
        recipe.events.reduce(0) { total, spec in
            total + resolvedMinutes(for: spec) * spec.count
        }
    }

    // MARK: - Optimization Results

    @ViewBuilder
    private var optimizationResultsSection: some View {
        switch optimizationState {
        case .idle:
            EmptyView()

        case .optimizing:
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Optimizing")
                    .font(.headline)
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: DS.Spacing.md) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Finding the best arrangement...")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(DS.Spacing.md)
                .skinPlatter(skin)
                .skinPlatterDepth(skin)
            }

        case .success(let scenarios):
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Results")
                    .font(.headline)
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: DS.Spacing.xs) {
                    ForEach(Array(scenarios.prefix(3).enumerated()), id: \.offset) { index, scenario in
                        scenarioCard(scenario, index: index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.md)
                .skinPlatter(skin)
                .skinPlatterDepth(skin)
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Could not optimize")
                    .font(.headline)
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(skin.resolvedDestructiveColor)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextPrimary)
                    }

                    Text("Try adjusting your settings above and re-optimizing.")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.md)
                .skinPlatter(skin)
                .skinPlatterDepth(skin)
            }
        }
    }

    private func scenarioCard(_ scenario: ScheduleScenario, index: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                if index == 0 {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(skin.accentColor)
                }
                Text("Option \(index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextPrimary)
                Text("(\(Int(scenario.fitness * 100))% fit)")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextSecondary)
                Spacer()

                if let service = optimizerService, let rs = reminderService {
                    Button {
                        Haptics.impact()
                        service.applyRecipeScenario(at: index, to: rs)
                        onDone?()
                    } label: {
                        Text("Apply")
                    }
                    .buttonStyle(.action(role: .primary, size: .compact))
                }
            }

            // Show gene details
            ForEach(Array(scenario.genes.prefix(5).enumerated()), id: \.offset) { _, gene in
                HStack(spacing: DS.Spacing.sm) {
                    Circle()
                        .fill(gene.isFocusBlock ? skin.accentColor : skin.resolvedTextTertiary)
                        .frame(width: 6, height: 6)
                    Text(gene.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(DS.timeFormatter.string(from: gene.startTime))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
            }
        }
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.sm)
        .background(
            index == 0
                ? AnyShapeStyle(skin.accentColor.opacity(0.08))
                : AnyShapeStyle(skin.resolvedPlatterMaterial.opacity(0.3))
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))
    }

    // MARK: - Blocked Empty State

    private var blockedEmptyState: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
                Spacer(minLength: DS.Spacing.xl)

                Image(systemName: "tray")
                    .font(.system(size: 32))
                    .foregroundStyle(skin.resolvedTextTertiary)

                VStack(spacing: DS.Spacing.xs) {
                    Text("\(recipe.name) needs tasks")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(skin.resolvedTextPrimary)
                    Text("This recipe rearranges your existing tasks.\nAdd some first, or try one that creates new blocks.")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Spacing.lg)
                }

                if onAddTasks != nil {
                    Button {
                        Haptics.tap()
                        onAddTasks?()
                    } label: {
                        Label("Add tasks", systemImage: "plus")
                    }
                    .buttonStyle(.action(role: .primary, size: .compact))
                }

                // Suggest creative alternatives
                if let onSwitchRecipe, !suggestedAlternatives.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Try instead")
                            .font(.headline)
                            .foregroundStyle(skin.resolvedTextPrimary)
                            .accessibilityAddTraits(.isHeader)

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(suggestedAlternatives) { alt in
                                Button {
                                    Haptics.tap()
                                    onSwitchRecipe(alt)
                                } label: {
                                    HStack(spacing: DS.Spacing.sm) {
                                        Image(systemName: alt.icon)
                                            .font(.caption)
                                            .foregroundStyle(skin.accentColor)
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(alt.name)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(skin.resolvedTextPrimary)
                                            Text(alt.description)
                                                .font(.caption2)
                                                .foregroundStyle(skin.resolvedTextSecondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(skin.resolvedTextTertiary)
                                    }
                                    .padding(.vertical, DS.Spacing.sm)
                                    .padding(.horizontal, DS.Spacing.sm)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.md)
                        .skinPlatter(skin)
                        .skinPlatterDepth(skin)
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                }

                Spacer(minLength: DS.Spacing.xl)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(action: onCancel) {
                Text("Cancel")
            }
            .buttonStyle(.action(role: .secondary))
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(action: {
                Haptics.tap()
                executeOptimization()
            }) {
                HStack(spacing: DS.Spacing.xs) {
                    if case .optimizing = optimizationState {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: actionButtonIcon)
                    }
                    Text(actionButtonLabel)
                }
            }
            .buttonStyle(.action(role: .primary))
            .disabled(!canExecute)
            .opacity(canExecute ? 1.0 : 0.5)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .frame(height: DS.Size.actionFooterHeight)
        .skinBarBackground(skin)
    }

    // MARK: - Execute Optimization

    private func executeOptimization() {
        guard let service = optimizerService, let rs = reminderService else {
            // Fall back to the legacy callback path
            onExecute(recipe, paramValues)
            return
        }

        optimizationState = .optimizing

        Task {
            let result = await service.executeRecipe(
                recipe,
                paramValues: paramValues,
                reminderService: rs
            )

            switch result {
            case .success(let optimizerResult):
                optimizationState = .success(optimizerResult.scenarios)
                Haptics.impact()

            case .partialSuccess(let optimizerResult, let warnings):
                if optimizerResult.scenarios.isEmpty {
                    optimizationState = .error(warnings.first ?? "Partial result with no scenarios")
                } else {
                    optimizationState = .success(optimizerResult.scenarios)
                    Haptics.impact()
                }

            case .noEventsToOptimize:
                optimizationState = .error("No events to optimize")

            case .infeasible(let reason):
                optimizationState = .error(reason)
            }
        }
    }

    // MARK: - Settings Section (all params in one platter)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            ForEach(Array(recipe.params.enumerated()), id: \.element.id) { index, param in
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(param.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(skin.resolvedTextPrimary)
                    paramControl(for: param)
                }

                if index < recipe.params.count - 1 {
                    SkinSeparator()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.md)
        .skinPlatter(skin)
        .skinPlatterDepth(skin)
    }

    @ViewBuilder
    private func paramControl(for param: RecipeParam) -> some View {
        switch param.kind {
        case .segmented(let options):
            segmentedParam(id: param.id, options: options)

        case .stepper(let min, let max):
            stepperParam(id: param.id, range: min...max)

        case .text:
            textParam(id: param.id)

        case .hourPicker(let range):
            hourPickerParam(id: param.id, range: range)

        case .eventPicker:
            eventPickerParam(id: param.id)

        case .eventMultiPicker:
            eventMultiPickerParam(id: param.id)
        }
    }

    // MARK: - Parameter Controls

    private func segmentedParam(id: String, options: [Int]) -> some View {
        let binding = Binding<Int>(
            get: { paramValues[id] as? Int ?? options.first ?? 0 },
            set: { paramValues[id] = $0 }
        )

        return SegmentedPillPicker(
            options: options,
            selection: binding,
            labelProvider: { minutes in
                if minutes < 60 { return "\(minutes)m" }
                let hours = minutes / 60
                let rem = minutes % 60
                if rem == 0 { return "\(hours)h" }
                return "\(hours)h\(rem)m"
            }
        )
    }

    private func stepperParam(id: String, range: ClosedRange<Int>) -> some View {
        let binding = Binding<Int>(
            get: { paramValues[id] as? Int ?? range.lowerBound },
            set: { paramValues[id] = $0 }
        )

        return Stepper(value: binding, in: range) {
            Text("\(binding.wrappedValue)")
                .font(.system(.body, design: .monospaced, weight: .medium))
                .foregroundStyle(skin.resolvedTextPrimary)
        }
    }

    private func textParam(id: String) -> some View {
        let binding = Binding<String>(
            get: { paramValues[id] as? String ?? "" },
            set: { paramValues[id] = $0 }
        )

        return TextField("Enter value", text: binding)
            .textFieldStyle(.plain)
            .font(.body)
            .padding(DS.Spacing.sm)
            .background(skin.resolvedPlatterMaterial.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))
    }

    private func hourPickerParam(id: String, range: ClosedRange<Int>) -> some View {
        let binding = Binding<Int>(
            get: { paramValues[id] as? Int ?? range.lowerBound },
            set: { paramValues[id] = $0 }
        )

        return Picker("", selection: binding) {
            ForEach(Array(range), id: \.self) { hour in
                Text("\(hour):00").tag(hour)
            }
        }
        .labelsHidden()
        .frame(width: 100)
    }

    private func eventPickerParam(id: String) -> some View {
        let binding = Binding<String>(
            get: { paramValues[id] as? String ?? "" },
            set: { paramValues[id] = $0 }
        )

        return TextField("Select event", text: binding)
            .textFieldStyle(.plain)
            .font(.body)
            .padding(DS.Spacing.sm)
            .background(skin.resolvedPlatterMaterial.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))
    }

    private func eventMultiPickerParam(id: String) -> some View {
        let events = localEventsForPicker

        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if events.isEmpty {
                // Inline empty hint (main blocked state handles the full empty view)
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                    Text("No upcoming tasks found")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .padding(.vertical, DS.Spacing.sm)
            } else {
                // Select all / none toggle
                HStack {
                    let allSelected = selectedEventIds.count == events.count
                    Button {
                        if allSelected {
                            selectedEventIds.removeAll()
                        } else {
                            selectedEventIds = Set(events.map(\.id))
                        }
                        paramValues[id] = Array(selectedEventIds)
                    } label: {
                        Text(allSelected ? "Deselect all" : "Select all")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(skin.accentColor)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("\(selectedEventIds.count) of \(events.count)")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }

                ForEach(events, id: \.id) { event in
                    eventRow(event: event, paramId: id)
                }
            }
        }
    }

    private func eventRow(event: CalendarEvent, paramId: String) -> some View {
        let isSelected = selectedEventIds.contains(event.id)

        return Button {
            if isSelected {
                selectedEventIds.remove(event.id)
            } else {
                selectedEventIds.insert(event.id)
            }
            paramValues[paramId] = Array(selectedEventIds)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? skin.accentColor : skin.resolvedTextTertiary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(skin.resolvedTextPrimary)

                    Text(event.formattedTimeRange)
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextSecondary)
                }

                Spacer()

                Text("\(Int(event.duration / 60))m")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .padding(.vertical, DS.Spacing.xs)
            .padding(.horizontal, DS.Spacing.sm)
            .background(isSelected ? skin.accentColor.opacity(0.06) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var localEventsForPicker: [CalendarEvent] {
        guard let service = reminderService else { return [] }
        return service.localEvents
            .filter { $0.isUpcoming }
            .sorted { $0.startDate < $1.startDate }
    }

    private func resolvedMinutes(for spec: EventSpec) -> Int {
        // Check if a param overrides this spec's minutes
        if let idx = recipe.events.firstIndex(where: { $0.title == spec.title }),
           let param = recipe.params.first(where: {
               if case .eventMinutes(let i) = $0.target { return i == idx }
               return false
           }),
           let value = paramValues[param.id] as? Int {
            return value
        }
        return spec.minutes
    }

    private func formatDuration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    // MARK: - Default Values

    private func initializeDefaults() {
        for param in recipe.params {
            switch param.kind {
            case .segmented(let options):
                if paramValues[param.id] == nil {
                    paramValues[param.id] = defaultForParam(param) ?? options.first
                }
            case .stepper(let min, _):
                if paramValues[param.id] == nil {
                    paramValues[param.id] = defaultForParam(param) ?? min
                }
            case .hourPicker(let range):
                if paramValues[param.id] == nil {
                    paramValues[param.id] = defaultForParam(param) ?? range.lowerBound
                }
            case .text, .eventPicker:
                break
            case .eventMultiPicker:
                if selectedEventIds.isEmpty {
                    let allIds = localEventsForPicker.map(\.id)
                    selectedEventIds = Set(allIds)
                    paramValues[param.id] = allIds
                }
            }
        }
    }

    private func defaultForParam(_ param: RecipeParam) -> Int? {
        switch param.target {
        case .eventMinutes(let index):
            guard index < recipe.events.count else { return nil }
            return recipe.events[index].minutes
        case .eventCount(let index):
            guard index < recipe.events.count else { return nil }
            return recipe.events[index].count
        case .workingHoursStart:
            return recipe.workingHours?.start
        case .workingHoursEnd:
            return recipe.workingHours?.end
        case .maxMeetings:
            return recipe.maxMeetingsPerDay
        case .peakEnergy:
            return recipe.peakEnergyHour
        default:
            return nil
        }
    }
}
