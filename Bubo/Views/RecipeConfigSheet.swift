import SwiftUI

// MARK: - Optimization State

private enum OptimizationState: Equatable {
    case idle
    case optimizing
    case success([ScheduleScenario], warnings: [String] = [])
    case error(String, snapshot: ScheduleSnapshot? = nil)

    static func == (lhs: OptimizationState, rhs: OptimizationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.optimizing, .optimizing): return true
        case (.success(let a, _), .success(let b, _)):
            return a.map(\.fitness) == b.map(\.fitness)
        case (.error(let a, _), .error(let b, _)): return a == b
        default: return false
        }
    }
}

// MARK: - Recipe Config Sheet

/// Unified recipe detail view: configure → optimize → review → apply.
/// All states live on one scrollable screen. Footer adapts to current state.
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
    @State private var selectedScenarioIndex = 0
    @State private var currentSnapshot: ScheduleSnapshot?

    // MARK: - Computed

    private var isBlockedByNoEvents: Bool {
        recipe.needsExistingEvents && localEventsForPicker.isEmpty
    }

    private var canExecute: Bool {
        if isBlockedByNoEvents { return false }
        if case .optimizing = optimizationState { return false }
        if recipe.params.contains(where: { $0.kind == .eventMultiPicker }) {
            return !selectedEventIds.isEmpty
        }
        return true
    }

    private var hasResults: Bool {
        if case .success(let s, _) = optimizationState { return !s.isEmpty }
        return false
    }

    private var scenarios: [ScheduleScenario] {
        if case .success(let s, _) = optimizationState { return s }
        return []
    }

    private var suggestedAlternatives: [ScheduleRecipe] {
        RecipeCatalog.quickActions.filter { $0.isCreative }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if isBlockedByNoEvents {
                blockedEmptyState
            } else {
                normalConfigFlow
            }

            SkinSeparator()
            footer
        }
        .onAppear {
            initializeDefaults()
            loadScheduleSnapshot()
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

                // Parameters — each as its own section
                if !recipe.params.isEmpty {
                    settingsSections
                }

                // Preview for creative recipes with multiple events
                if recipe.isCreative && recipe.events.count > 1 {
                    creativePreviewSection
                }

                // Schedule context — show what the optimizer will work with
                if let snapshot = currentSnapshot, !hasResults {
                    scheduleContextSection(snapshot)
                }

                // Inline optimization state
                optimizationResultsSection
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Recipe Header

    private var recipeHeader: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(recipe.name)
                .font(.headline)
                .foregroundStyle(skin.resolvedTextPrimary)
            if !recipe.description.isEmpty {
                Text(recipe.description)
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(recipe.name): \(recipe.description)")
    }

    // MARK: - Settings Sections

    private var settingsSections: some View {
        ForEach(recipe.params, id: \.id) { param in
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(param.label)
                    .font(.headline)
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    paramControl(for: param)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.md)
                .skinPlatter(skin)
                .skinPlatterDepth(skin)
            }
        }
    }

    // MARK: - Creative Preview

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
                ForEach(Array(recipe.events.enumerated()), id: \.offset) { index, spec in
                    let minutes = resolvedMinutes(for: spec)
                    HStack(spacing: DS.Spacing.sm) {
                        RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius)
                            .fill(skin.accentColor.opacity(index % 2 == 0 ? 0.8 : 0.5))
                            .frame(width: DS.Size.accentBarWidth, height: DS.Size.iconLarge)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(spec.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(skin.resolvedTextPrimary)
                            if let offset = spec.startOffsetMinutes, offset > 0 {
                                Text("in \(formatDuration(offset))")
                                    .font(.caption2)
                                    .foregroundStyle(skin.resolvedTextSecondary)
                            }
                        }

                        if spec.count > 1 {
                            Text("×\(spec.count)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(skin.accentColor)
                                .padding(.horizontal, DS.Spacing.xs)
                                .padding(.vertical, 1)
                                .background(skin.accentColor.opacity(DS.Opacity.lightFill))
                                .clipShape(Capsule())
                        }

                        Spacer()

                        Text(formatDuration(minutes * spec.count))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(skin.resolvedTextSecondary)
                    }
                }

                SkinSeparator()

                HStack {
                    Text("Total")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(skin.resolvedTextSecondary)
                    Spacer()
                    Text(formatDuration(totalCreativeMinutes))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(skin.resolvedTextPrimary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.md)
            .skinPlatter(skin)
            .skinPlatterDepth(skin)
        }
    }

    // MARK: - Schedule Context

    private func scheduleContextSection(_ snapshot: ScheduleSnapshot) -> some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"
        let freeTotal = Int(snapshot.freeGaps.reduce(0.0) { $0 + $1.duration } / 60)
        let longestGap = Int((snapshot.freeGaps.map(\.duration).max() ?? 0) / 60)

        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Your Schedule")
                .font(.headline)
                .foregroundStyle(skin.resolvedTextPrimary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                scheduleTimeline(snapshot)

                HStack(spacing: DS.Spacing.md) {
                    Label("\(freeTotal)m free", systemImage: "clock")
                    Label("longest gap \(longestGap)m", systemImage: "arrow.left.and.right")
                }
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextSecondary)
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
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    let fraction = CGFloat(segment.minutes) / CGFloat(total)
                    RoundedRectangle(cornerRadius: DS.Size.previewCardRadius)
                        .fill(
                            LinearGradient(
                                colors: [
                                    skin.accentColor.opacity(index % 2 == 0 ? 0.8 : 0.5),
                                    skin.accentColor.opacity(index % 2 == 0 ? 0.6 : 0.35),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: max(fraction * geo.size.width - 1.5, 6))
                        .overlay(
                            Group {
                                if fraction * geo.size.width > 36 {
                                    Text("\(segment.minutes)m")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(skin.resolvedTextPrimary.opacity(0.9))
                                }
                            }
                        )
                }
            }
        }
        .frame(height: 24)
        .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewCardRadius))
    }

    private var totalCreativeMinutes: Int {
        recipe.events.reduce(0) { $0 + resolvedMinutes(for: $1) * $1.count }
    }

    // MARK: - Optimization Results (inline)

    @ViewBuilder
    private var optimizationResultsSection: some View {
        switch optimizationState {
        case .idle:
            EmptyView()

        case .optimizing:
            VStack(spacing: DS.Spacing.md) {
                ProgressView()
                    .controlSize(.regular)
                Text(recipe.isCreative ? "Finding the best time…" : "Optimizing schedule…")
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(DS.Spacing.lg)

        case .success(let results, let warnings):
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                // Warnings banner
                if !warnings.isEmpty {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedWarningColor)
                        Text(warnings.joined(separator: ". "))
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedWarningColor)
                    }
                }

                // Scenario picker (segmented) when multiple options
                if results.count > 1 {
                    Picker("Option", selection: $selectedScenarioIndex) {
                        ForEach(0..<results.count, id: \.self) { idx in
                            Text("Option \(idx + 1)").tag(idx)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Selected scenario detail
                if selectedScenarioIndex < results.count {
                    scenarioDetail(results[selectedScenarioIndex])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.md)
            .skinPlatter(skin)
            .skinPlatterDepth(skin)

        case .error(let message, let snapshot):
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedWarningColor)

                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text(friendlyErrorTitle(message))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(skin.resolvedTextPrimary)
                        if !recipe.params.isEmpty && !isAtMinimumDuration {
                            Text("Try a shorter duration above.")
                                .font(.caption2)
                                .foregroundStyle(skin.resolvedTextSecondary)
                        }
                    }
                }

                // Update the context snapshot with optimizer's actual view
                if let snapshot, currentSnapshot == nil {
                    scheduleTimeline(snapshot)
                }

                if recipe.horizon == .today {
                    Button(action: {
                        retryWithTomorrow()
                    }) {
                        Label("Try Tomorrow", systemImage: "arrow.forward.circle")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(skin.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DS.Size.cornerRadius)
                    .fill(skin.resolvedWarningColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.cornerRadius)
                    .strokeBorder(skin.resolvedWarningColor.opacity(0.2), lineWidth: 1)
            )
        }
    }

    private func scenarioDetail(_ scenario: ScheduleScenario) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Fitness badge
            Label("\(Int(max(0, scenario.fitness) * 100))% match", systemImage: "sparkles")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(skin.accentColor)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .background(skin.accentColor.opacity(0.12))
                .clipShape(Capsule())

            // Events list
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

                    Text("\(DS.timeFormatter.string(from: gene.startTime)) – \(DS.timeFormatter.string(from: gene.endTime))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
            }

            // Warnings
            if !scenario.constraintViolations.isEmpty {
                ForEach(scenario.constraintViolations, id: \.self) { v in
                    Label(v, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedWarningColor)
                }
            }
        }
    }

    /// Whether the current duration param is already at the minimum segmented option.
    private var isAtMinimumDuration: Bool {
        guard let param = recipe.params.first(where: {
            if case .segmented = $0.kind { return true }
            return false
        }) else { return false }
        if case .segmented(let options) = param.kind,
           let current = paramValues[param.id] as? Int,
           let smallest = options.min() {
            return current <= smallest
        }
        return false
    }

    private var durationHint: String {
        isAtMinimumDuration
            ? "Try a different day or free up time in your calendar."
            : "Try a shorter duration."
    }

    private func friendlyErrorTitle(_ raw: String) -> String {
        if raw.contains("largest free gap") {
            // Extract gap size from "largest free gap is X min"
            let gapInfo = extractMinutes(from: raw, after: "largest free gap is")
            let detail = gapInfo.map { " (largest gap: \($0)m)" } ?? ""
            return recipe.isCreative
                ? "No free slot long enough for this block\(detail). \(durationHint)"
                : "No free slot long enough\(detail). \(durationHint)"
        }
        if raw.contains("hard constraints") || raw.contains("Cannot satisfy") {
            return recipe.isCreative
                ? "Schedule too packed for this block. \(durationHint)"
                : "Can't rearrange with these constraints. Try fewer tasks."
        }
        if raw.contains("No events") {
            return "No events to work with."
        }
        if raw.contains("No working time left") {
            return "Working hours are over for today. Try scheduling for tomorrow."
        }
        if raw.contains("but only") && raw.contains("min") {
            let available = extractMinutes(from: raw, after: "only")
            let detail = available.map { " (\($0)m free)" } ?? ""
            return "Not enough free time in schedule\(detail). \(durationHint)"
        }
        return raw
    }

    /// Visual timeline showing occupied vs free time, similar to previewTimeline.
    private func scheduleTimeline(_ snapshot: ScheduleSnapshot) -> some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"

        // Build segments: alternating occupied/free across working hours
        let segments = buildTimelineSegments(snapshot)
        let totalDuration = max(segments.reduce(0.0) { $0 + $1.duration }, 1)

        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        let fraction = CGFloat(segment.duration / totalDuration)
                        let width = max(fraction * geo.size.width - 1, 4)

                        RoundedRectangle(cornerRadius: DS.Size.previewCardRadius)
                            .fill(
                                segment.isFree
                                    ? LinearGradient(
                                        colors: [
                                            skin.accentColor.opacity(0.7),
                                            skin.accentColor.opacity(0.5),
                                        ],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                    : LinearGradient(
                                        colors: [
                                            skin.resolvedTextTertiary.opacity(0.25),
                                            skin.resolvedTextTertiary.opacity(0.15),
                                        ],
                                        startPoint: .top, endPoint: .bottom
                                    )
                            )
                            .frame(width: width)
                            .overlay(
                                Group {
                                    if segment.isFree && width > 30 {
                                        Text("\(Int(segment.duration / 60))m")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(skin.resolvedTextPrimary.opacity(0.9))
                                    }
                                }
                            )
                    }
                }
            }
            .frame(height: 24)
            .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewCardRadius))

            // Time labels below the bar
            HStack {
                Text(formatter.string(from: snapshot.planningHorizon.start))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(skin.resolvedTextTertiary)
                Spacer()
                let freeTotal = Int(snapshot.freeGaps.reduce(0.0) { $0 + $1.duration } / 60)
                Text("\(freeTotal)m free")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(skin.resolvedTextSecondary)
                Spacer()
                Text(formatter.string(from: snapshot.planningHorizon.end))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
        }
    }

    private struct TimelineSegment {
        let duration: TimeInterval
        let isFree: Bool
    }

    /// Turns free gaps + working hours into alternating occupied/free segments.
    private func buildTimelineSegments(_ snapshot: ScheduleSnapshot) -> [TimelineSegment] {
        let sortedGaps = snapshot.freeGaps.sorted { $0.start < $1.start }
        var segments: [TimelineSegment] = []
        var cursor = snapshot.planningHorizon.start

        for gap in sortedGaps {
            // Occupied block before this gap
            let occupied = gap.start.timeIntervalSince(cursor)
            if occupied > 0 {
                segments.append(TimelineSegment(duration: occupied, isFree: false))
            }
            // Free gap
            segments.append(TimelineSegment(duration: gap.duration, isFree: true))
            cursor = gap.end
        }

        // Trailing occupied block
        let trailing = snapshot.planningHorizon.end.timeIntervalSince(cursor)
        if trailing > 0 {
            segments.append(TimelineSegment(duration: trailing, isFree: false))
        }

        return segments
    }

    /// Extracts first integer after a keyword in a string like "largest free gap is 15 min".
    private func extractMinutes(from text: String, after keyword: String) -> Int? {
        guard let range = text.range(of: keyword) else { return nil }
        let after = text[range.upperBound...]
        let digits = after.drop(while: { !$0.isNumber })
        let number = digits.prefix(while: { $0.isNumber })
        return Int(number)
    }

    // MARK: - Footer (adapts to state)

    private var footer: some View {
        HStack {
            Spacer()

            Button(action: {
                if hasResults {
                    optimizationState = .idle
                    selectedScenarioIndex = 0
                } else {
                    onCancel()
                }
            }) {
                Text(hasResults ? "Back" : "Cancel")
            }
            .buttonStyle(.action(role: .secondary))
            .keyboardShortcut(.cancelAction)

            if hasResults {
                Button(action: {
                    Haptics.impact()
                    applySelectedScenario()
                }) {
                    Label("Apply Schedule", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.action(role: .primary))
                .keyboardShortcut(.defaultAction)
            } else {
                Button(action: {
                    Haptics.tap()
                    executeOptimization()
                }) {
                    HStack(spacing: DS.Spacing.xs) {
                        if case .optimizing = optimizationState {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: recipe.isCreative ? "calendar.badge.plus" : "wand.and.stars")
                        }
                        Text(footerActionLabel)
                    }
                }
                .buttonStyle(.action(role: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!canExecute)
                .opacity(canExecute ? 1.0 : 0.5)
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .frame(height: DS.Size.actionFooterHeight)
        .skinBarBackground(skin)
    }

    private var footerActionLabel: String {
        switch optimizationState {
        case .optimizing: return recipe.isCreative ? "Finding…" : "Optimizing…"
        case .error: return "Retry"
        default: return recipe.actionLabel
        }
    }

    // MARK: - Actions

    private func loadScheduleSnapshot() {
        guard let rs = reminderService, let service = optimizerService else { return }

        let cal = Calendar.current
        let now = Date()
        let workingHours = recipe.workingHours?.closedRange ?? service.workingHours

        // Determine horizon for the snapshot
        let horizon: DateInterval
        switch recipe.horizon {
        case .today:
            let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            horizon = DateInterval(start: now, end: todayEnd)
        case .tomorrow:
            let tomorrowStart = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            let tomorrowEnd = cal.date(byAdding: .day, value: 1, to: tomorrowStart)!
            horizon = DateInterval(start: tomorrowStart, end: tomorrowEnd)
        case .week:
            let weekEnd = cal.date(byAdding: .day, value: 7, to: now)!
            horizon = DateInterval(start: now, end: weekEnd)
        }

        // For find-slot recipes, include local events as occupied time too — the optimizer
        // treats them as fixed obstacles, so the snapshot should reflect that.
        let fixedEvents = recipe.findSlotOnly
            ? rs.allEvents
            : rs.allEvents.filter { !$0.isLocalEvent }
        var gaps: [DateInterval] = []
        var day = cal.startOfDay(for: horizon.start)

        while day < horizon.end {
            guard let workStart = cal.date(bySettingHour: workingHours.lowerBound, minute: 0, second: 0, of: day),
                  let workEnd = cal.date(bySettingHour: workingHours.upperBound, minute: 0, second: 0, of: day) else {
                day = cal.date(byAdding: .day, value: 1, to: day)!
                continue
            }

            let effectiveStart = max(workStart, max(now, horizon.start))
            let effectiveEnd = min(workEnd, horizon.end)

            if effectiveEnd > effectiveStart {
                let overlapping = fixedEvents
                    .compactMap { fixed -> (start: Date, end: Date)? in
                        let oStart = max(fixed.startDate, effectiveStart)
                        let oEnd = min(fixed.endDate, effectiveEnd)
                        return oEnd > oStart ? (oStart, oEnd) : nil
                    }
                    .sorted { $0.start < $1.start }

                var cursor = effectiveStart
                for fixed in overlapping {
                    if fixed.start > cursor {
                        gaps.append(DateInterval(start: cursor, end: fixed.start))
                    }
                    cursor = max(cursor, fixed.end)
                }
                if effectiveEnd > cursor {
                    gaps.append(DateInterval(start: cursor, end: effectiveEnd))
                }
            }

            day = cal.date(byAdding: .day, value: 1, to: day)!
        }

        currentSnapshot = ScheduleSnapshot(freeGaps: gaps, workingHours: workingHours, planningHorizon: horizon)
    }

    private func executeOptimization() {
        guard let service = optimizerService, let rs = reminderService else {
            onExecute(recipe, paramValues)
            return
        }

        optimizationState = .optimizing
        selectedScenarioIndex = 0

        Task {
            let result = await service.executeRecipe(
                recipe,
                paramValues: paramValues,
                reminderService: rs
            )

            switch result {
            case .success(let r):
                optimizationState = .success(r.scenarios)
                Haptics.impact()
            case .partialSuccess(let r, let warnings):
                if r.scenarios.isEmpty {
                    optimizationState = .error(warnings.first ?? "No scenarios found")
                } else {
                    optimizationState = .success(r.scenarios, warnings: warnings)
                    Haptics.impact()
                }
            case .noEventsToOptimize:
                optimizationState = .error("No events to optimize")
            case .infeasible(let reason, let snapshot):
                if let snapshot { currentSnapshot = snapshot }
                optimizationState = .error(reason, snapshot: snapshot)
            }
        }
    }

    private func retryWithTomorrow() {
        var tomorrowRecipe = recipe
        tomorrowRecipe.horizon = .tomorrow
        guard let service = optimizerService, let rs = reminderService else { return }

        optimizationState = .optimizing
        selectedScenarioIndex = 0

        Task {
            let result = await service.executeRecipe(
                tomorrowRecipe,
                paramValues: paramValues,
                reminderService: rs
            )

            switch result {
            case .success(let r):
                optimizationState = .success(r.scenarios)
                Haptics.impact()
            case .partialSuccess(let r, let warnings):
                if r.scenarios.isEmpty {
                    optimizationState = .error(warnings.first ?? "No scenarios found")
                } else {
                    optimizationState = .success(r.scenarios, warnings: warnings)
                    Haptics.impact()
                }
            case .noEventsToOptimize:
                optimizationState = .error("No events to optimize")
            case .infeasible(let reason, let snapshot):
                if let snapshot { currentSnapshot = snapshot }
                optimizationState = .error(reason, snapshot: snapshot)
            }
        }
    }

    private func applySelectedScenario() {
        guard let service = optimizerService, let rs = reminderService else { return }
        service.applyRecipeScenario(at: selectedScenarioIndex, to: rs)
        onDone?()
    }

    // MARK: - Blocked Empty State

    private var blockedEmptyState: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
                Spacer(minLength: DS.Spacing.xl)

                Image(systemName: "tray")
                    .font(.system(size: 32))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .accessibilityHidden(true)

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

                if let onSwitchRecipe, !suggestedAlternatives.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Try instead")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(skin.resolvedTextTertiary)
                            .padding(.bottom, DS.Spacing.xs)
                            .accessibilityAddTraits(.isHeader)

                        ForEach(suggestedAlternatives) { alt in
                            Button {
                                Haptics.tap()
                                onSwitchRecipe(alt)
                            } label: {
                                HStack(spacing: DS.Spacing.sm) {
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
                    .padding(.horizontal, DS.Spacing.lg)
                }

                Spacer(minLength: DS.Spacing.xl)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Parameter Controls

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
        case .periodPicker:
            periodPickerParam(id: param.id)
        }
    }

    private func segmentedParam(id: String, options: [Int]) -> some View {
        let binding = Binding<Int>(
            get: { paramValues[id] as? Int ?? options.first ?? 0 },
            set: { newValue in
                paramValues[id] = newValue
                // Clear error so user sees "Find Best Time" again after adjusting
                if case .error = optimizationState {
                    optimizationState = .idle
                }
            }
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
            set: { newValue in
                paramValues[id] = newValue
                if case .error = optimizationState {
                    optimizationState = .idle
                }
            }
        )
        return SegmentedPillPicker(
            options: Array(range),
            selection: binding,
            labelProvider: { "\($0)" }
        )
    }

    private func textParam(id: String) -> some View {
        let binding = Binding<String>(
            get: { paramValues[id] as? String ?? "" },
            set: { paramValues[id] = $0 }
        )
        return TextField("Enter value", text: binding)
            .textFieldStyle(.plain)
            .font(.headline)
    }

    private func hourPickerParam(id: String, range: ClosedRange<Int>) -> some View {
        let binding = Binding<Int>(
            get: { paramValues[id] as? Int ?? range.lowerBound },
            set: { newValue in
                paramValues[id] = newValue
                if case .error = optimizationState {
                    optimizationState = .idle
                }
            }
        )
        return SegmentedPillPicker(
            options: Array(range),
            selection: binding,
            labelProvider: { "\($0):00" }
        )
    }

    private func periodPickerParam(id: String) -> some View {
        // Options: nil = any time, then each Period case
        let options: [(label: String, value: String)] = [
            ("Any time", ""),
            ("Morning 7–12", Period.morning.rawValue),
            ("Afternoon 12–17", Period.afternoon.rawValue),
            ("Evening 17–21", Period.evening.rawValue),
        ]
        let binding = Binding<String>(
            get: { paramValues[id] as? String ?? findDefaultPeriod(paramId: id) },
            set: { newValue in
                paramValues[id] = newValue
                if case .error = optimizationState {
                    optimizationState = .idle
                }
            }
        )
        return SegmentedPillPicker(
            options: options.map(\.value),
            selection: binding,
            labelProvider: { value in
                options.first { $0.value == value }?.label ?? value
            }
        )
    }

    /// Find the default period for a period param by looking at the recipe's event spec.
    private func findDefaultPeriod(paramId: String) -> String {
        guard let param = recipe.params.first(where: { $0.id == paramId }),
              case .eventPeriod(let index) = param.target,
              index < recipe.events.count else { return "" }
        return recipe.events[index].period?.rawValue ?? ""
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
            .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
    }

    private func eventMultiPickerParam(id: String) -> some View {
        let events = localEventsForPicker

        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if events.isEmpty {
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
                    .font(.system(size: DS.Size.iconLarge))
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
            .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(event.title), \(event.formattedTimeRange)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Helpers

    private var localEventsForPicker: [CalendarEvent] {
        guard let service = reminderService else { return [] }
        return service.localEvents
            .filter { $0.isUpcoming }
            .sorted { $0.startDate < $1.startDate }
    }

    private func resolvedMinutes(for spec: EventSpec) -> Int {
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
