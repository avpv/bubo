import SwiftUI

// MARK: - Command Palette
//
// Single entry point for all schedule optimization.
//
// Design (Birman):
// - One input field: searches presets AND accepts natural language for AI
// - Presets are starting points, not final configs — expand to compose intents
// - Intent chips: add/remove atomic scheduling rules visually
// - Live preview: see concrete event times before committing
// - Conflict warnings: contradictions shown immediately
// - Enter runs, Esc closes, ↑↓ navigate, → expand, Tab all presets
// - No confirmation dialog — undo via toast

struct CommandPalette: View {
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var optimizerService: OptimizerService
    var reminderService: ReminderService
    var agentService: AgentService

    var seedEvent: CalendarEvent? = nil
    var seedSlotMinutes: Int? = nil
    var seedPreset: OptimizationRequest? = nil

    var onDismiss: () -> Void
    var onApplied: (_ request: OptimizationRequest, _ undo: @escaping () -> Void) -> Void

    // MARK: - State

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var expandedId: String? = nil
    @State private var showAll = false
    @State private var phase: Phase = .picking
    @State private var aiError: String? = nil
    @State private var dryRunPreview: String? = nil
    @State private var dryRunTask: Task<Void, Never>? = nil
    @State private var composedRequest: OptimizationRequest? = nil
    @State private var conflicts: [IntentConflictDetector.Conflict] = []
    @FocusState private var isSearchFocused: Bool

    private enum Phase: Equatable {
        case picking
        case working(String)
        case applied([EventInfo])
        case failed(String)
    }

    struct EventInfo: Equatable, Identifiable {
        let id: String
        let title: String
        let timeRange: String
    }

    // MARK: - Suggestions

    private var suggestions: [OptimizationRequest] {
        if let engine = optimizerService.suggestionEngine,
           let suggestion = engine.suggestion {
            var result = [suggestion.request]
            for preset in defaultsByTime {
                if result.count >= 5 { break }
                if !result.contains(where: { $0.name == preset.name }) {
                    result.append(preset)
                }
            }
            return result
        }
        return Array(defaultsByTime.prefix(5))
    }

    private var defaultsByTime: [OptimizationRequest] {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<11:  return [.organizeDay, .findFocus(), .scheduleBacklog]
        case 11..<15: return [.findFocus(), .scheduleBacklog, .lowEnergyDay]
        case 15..<19: return [.scheduleBacklog, .organizeDay, .planWeek]
        default:      return [.planWeek, .organizeDay, .scheduleBacklog]
        }
    }

    private var filtered: [OptimizationRequest] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return seedEvent != nil || seedSlotMinutes != nil
                ? Array(IntentPresets.all.prefix(8))
                : suggestions
        }
        return IntentPresets.all
            .filter { $0.matchesSearch(query) }
            .sorted {
                let l = ($0.name ?? "").lowercased().contains(query.lowercased())
                let r = ($1.name ?? "").lowercased().contains(query.lowercased())
                if l != r { return l }
                return ($0.name ?? "") < ($1.name ?? "")
            }
    }

    /// The active request for the composer — either a modified preset or the selected one.
    private var activeRequest: OptimizationRequest? {
        if let composed = composedRequest { return composed }
        guard let id = expandedId else { return nil }
        return filtered.first { $0.id == id }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Scrim
            Rectangle()
                .fill(Color.black.opacity(0.25))
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            card
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.xl)
                .frame(maxHeight: .infinity, alignment: .top)

            shortcuts
        }
        .onAppear {
            isSearchFocused = true
            if let seed = seedPreset {
                expandedId = seed.id
                composedRequest = seed
                revalidate(seed)
            }
            refreshPreview()
        }
        .onDisappear { dryRunTask?.cancel() }
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 0) {
            searchField
            SkinSeparator()
            content
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .fill(.ultraThickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(skin.accentColor.opacity(0.25), lineWidth: DS.Border.standard)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.rightArrow) {
            guard searchText.isEmpty, !filtered.isEmpty else { return .ignored }
            let idx = min(selectedIndex, filtered.count - 1)
            toggleExpand(filtered[idx])
            return .handled
        }
        .onKeyPress(.tab) {
            withAnimation(DS.Animation.quick) { showAll.toggle() }
            return .handled
        }
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }

    private func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    private func toggleExpand(_ request: OptimizationRequest) {
        withAnimation(DS.Animation.quick) {
            if expandedId == request.id {
                expandedId = nil
                composedRequest = nil
                conflicts = []
            } else {
                expandedId = request.id
                composedRequest = request
                revalidate(request)
            }
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: phaseIcon)
                .font(.body)
                .foregroundStyle(phaseColor)
                .symbolEffect(.pulse, isActive: isBusy)
                .frame(width: 18)

            TextField(placeholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(.headline)
                .focused($isSearchFocused)
                .disabled(isBusy)
                .onSubmit { handleSubmit() }
                .onChange(of: searchText) {
                    selectedIndex = 0
                    expandedId = nil
                    composedRequest = nil
                    conflicts = []
                    aiError = nil
                }

            if !searchText.isEmpty && !isBusy {
                Button {
                    searchText = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .buttonStyle(.plain)
            }

            Text("⌘K")
                .font(.caption2.monospaced())
                .foregroundStyle(skin.resolvedTextTertiary)
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(skin.resolvedTextTertiary.opacity(0.35), lineWidth: 0.5)
                )
                .opacity(isBusy ? 0.3 : 1)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.md)
    }

    private var phaseIcon: String {
        switch phase {
        case .picking: "sparkles"
        case .working: "hourglass"
        case .applied: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var phaseColor: Color {
        switch phase {
        case .picking, .working: skin.accentColor
        case .applied: skin.resolvedSuccessColor
        case .failed: skin.resolvedWarningColor
        }
    }

    private var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    private var placeholder: String {
        if seedEvent != nil { return "Change this event..." }
        if let m = seedSlotMinutes { return "Fill \(m) min slot..." }
        return "Find focus, plan day, or ask AI..."
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch phase {
                case .picking: pickingContent
                case .working(let label): statusView(label)
                case .applied(let events): appliedView(events)
                case .failed(let message): failedView(message)
                }
            }
            .padding(.vertical, DS.Spacing.sm)
        }
        .frame(maxHeight: 440)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Picking

    @ViewBuilder
    private var pickingContent: some View {
        if showAll && searchText.isEmpty {
            allPresetsView
        } else {
            // Context line
            if searchText.isEmpty {
                contextLine
            }

            // Preset list
            presetList

            // Intent composer (when a preset is expanded)
            if let request = activeRequest {
                intentComposer(request)
            }

            // AI fallback
            if !searchText.isEmpty && agentService.isConfigured {
                aiRow
            }

            // Footer
            footerHints

            if let aiError {
                Text(aiError)
                    .font(.caption)
                    .foregroundStyle(skin.resolvedWarningColor)
                    .padding(.horizontal, DS.Spacing.md)
            }
        }
    }

    private var contextLine: some View {
        HStack(spacing: DS.Spacing.xs) {
            if let seedEvent {
                Text("Change \u{201C}\(seedEvent.title)\u{201D}")
            } else if let m = seedSlotMinutes {
                Text("Free slot · \(m) min")
            } else {
                let fmt = DateFormatter()
                Text("Now \(fmt.setLocalizedDateFormatFromTemplate("H:mm"), fmt.string(from: Date())) · pick or compose")
            }
        }
        .font(.caption2)
        .foregroundStyle(skin.resolvedTextTertiary)
        .padding(.horizontal, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.xs)
    }

    // MARK: - Preset List

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, preset in
                presetRow(preset, index: index)
            }

            if filtered.isEmpty {
                VStack(spacing: DS.Spacing.xs) {
                    Text("No match for \u{201C}\(searchText)\u{201D}")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextSecondary)
                    Text("Press ↵ to ask AI")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.lg)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
    }

    private func presetRow(_ preset: OptimizationRequest, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let isExpanded = expandedId == preset.id
        let isTop = index == 0 && searchText.isEmpty && seedEvent == nil

        return HStack(spacing: DS.Spacing.sm) {
            Button { runRequest(composedRequest ?? preset) } label: {
                HStack(spacing: DS.Spacing.sm) {
                    Circle()
                        .fill(DS.Colors.categoryPalette[preset.categoryColorIndex])
                        .frame(width: isTop ? 10 : 6, height: isTop ? 10 : 6)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: isTop ? 2 : 1) {
                        Text(preset.name ?? "Optimize")
                            .font(isTop ? .headline.weight(.semibold) : .subheadline.weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(skin.resolvedTextPrimary)
                            .lineLimit(1)

                        if isTop, let preview = dryRunPreview {
                            Text(preview)
                                .font(.caption)
                                .foregroundStyle(skin.accentColor.opacity(0.85))
                                .lineLimit(1)
                        } else {
                            Text(preset.intents.prefix(3).map(\.label).joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(skin.resolvedTextSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expand chevron
            Button { toggleExpand(preset) } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, isTop ? DS.Spacing.sm : DS.Spacing.xs)
        .padding(.horizontal, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isTop
                    ? skin.accentColor.opacity(isSelected ? 0.18 : 0.08)
                    : (isSelected ? skin.accentColor.opacity(0.14) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTop ? skin.accentColor.opacity(0.20) : .clear, lineWidth: 0.5)
        )
        .onHover { if $0 { selectedIndex = index } }
    }

    // MARK: - Intent Composer

    @State private var composerPreview: String? = nil
    @State private var composerPreviewTask: Task<Void, Never>? = nil

    private func intentComposer(_ request: OptimizationRequest) -> some View {
        let graph = IntentGraph.build(from: request.intents)
        let phases = graph.intentsByPhase()
        let suggested = graph.suggestedIntents()

        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Active intents grouped by phase
            ForEach(phases, id: \.phase) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.phase.displayName.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .tracking(0.5)

                    FlowLayout(spacing: DS.Spacing.xs) {
                        ForEach(group.intents) { node in
                            chip(
                                node.intent.label,
                                active: true,
                                dimmed: node.isAutoResolved
                            ) {
                                guard !node.isAutoResolved else { return }
                                var m = request
                                m.toggle(node.intent)
                                updateComposed(m)
                            }
                        }
                    }
                }
            }

            // Suggested intents from graph
            if !suggested.isEmpty {
                Text("SUGGESTED")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .tracking(0.5)
                    .padding(.top, DS.Spacing.xxs)

                FlowLayout(spacing: DS.Spacing.xs) {
                    ForEach(Array(suggested.prefix(8).enumerated()), id: \.offset) { _, intent in
                        chip(intent.label, active: false) {
                            var m = request
                            m.add(intent)
                            updateComposed(m)
                        }
                    }
                }
            }

            // Available (full palette, less prominent)
            let available = request.availableIntents.filter { !suggested.contains($0) }
            if !available.isEmpty {
                Text("MORE")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .tracking(0.5)
                    .padding(.top, DS.Spacing.xxs)

                FlowLayout(spacing: DS.Spacing.xs) {
                    ForEach(Array(available.prefix(10).enumerated()), id: \.offset) { _, intent in
                        chip(intent.label, active: false) {
                            var m = request
                            m.add(intent)
                            updateComposed(m)
                        }
                    }
                }
            }

            // Conflict warnings
            if !conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(conflicts) { conflict in
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: conflictIcon(conflict.severity))
                                .font(.caption2)
                                .foregroundStyle(conflictColor(conflict.severity))
                            Text(conflict.message)
                                .font(.caption2)
                                .foregroundStyle(skin.resolvedTextSecondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.top, DS.Spacing.xxs)
            }

            // Live preview
            if let preview = composerPreview {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "eye.fill")
                        .font(.caption2)
                        .foregroundStyle(skin.accentColor.opacity(0.6))
                    Text(preview)
                        .font(.caption2)
                        .foregroundStyle(skin.accentColor.opacity(0.8))
                        .lineLimit(2)
                }
                .padding(.top, DS.Spacing.xxs)
                .transition(.opacity)
            }
        }
        .padding(DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(skin.accentColor.opacity(0.04))
        )
        .padding(.horizontal, DS.Spacing.sm)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .onAppear { refreshComposerPreview(request) }
    }

    private func updateComposed(_ request: OptimizationRequest) {
        composedRequest = request
        revalidate(request)
        refreshComposerPreview(request)
    }

    private func revalidate(_ request: OptimizationRequest) {
        conflicts = IntentConflictDetector.analyze(request.intents)
    }

    private func refreshComposerPreview(_ request: OptimizationRequest) {
        composerPreviewTask?.cancel()
        guard request.isCreative || request.findSlotOnly else {
            composerPreview = request.intents.map(\.label).joined(separator: " + ")
            return
        }
        composerPreviewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            var working = request
            working.speed = .quick
            working.maxScenarios = 1
            let genes = await optimizerService.executeDryRun(working, reminderService: reminderService)
            guard !Task.isCancelled else { return }
            if let genes, !genes.isEmpty {
                let fmt = DateFormatter()
                fmt.setLocalizedDateFormatFromTemplate("H:mm")
                composerPreview = genes.prefix(3).map {
                    "\($0.title) \(fmt.string(from: $0.startTime))–\(fmt.string(from: $0.endTime))"
                }.joined(separator: " · ")
            } else {
                composerPreview = "No feasible slot"
            }
        }
    }

    private func chip(_ label: String, active: Bool, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if dimmed {
                    Image(systemName: "link").font(.system(size: 7, weight: .semibold))
                }
                Text(label).font(.caption2.weight(.medium))
                if active && !dimmed {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(
                dimmed ? skin.resolvedTextTertiary
                : active ? .white
                : skin.resolvedTextPrimary
            )
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    dimmed ? skin.accentColor.opacity(0.05)
                    : active ? skin.accentColor
                    : skin.accentColor.opacity(0.10)
                )
            )
            .overlay(
                dimmed ? Capsule().strokeBorder(skin.resolvedTextTertiary.opacity(0.2), lineWidth: 0.5) : nil
            )
        }
        .buttonStyle(.plain)
        .help(dimmed ? "Auto-added dependency" : "")
    }

    private func conflictIcon(_ severity: IntentConflictDetector.Conflict.Severity) -> String {
        switch severity {
        case .error: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private func conflictColor(_ severity: IntentConflictDetector.Conflict.Severity) -> Color {
        switch severity {
        case .error: .red
        case .warning: skin.resolvedWarningColor
        case .info: skin.resolvedTextTertiary
        }
    }

    // MARK: - All Presets

    private var allPresetsView: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            ForEach(IntentPresets.allCategories) { category in
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .tracking(0.5)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.top, DS.Spacing.sm)

                    ForEach(category.presets) { preset in
                        presetRow(preset, index: -1)
                    }
                }
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
    }

    // MARK: - AI Row

    private var aiRow: some View {
        VStack(spacing: 0) {
            Divider().padding(.vertical, DS.Spacing.xs)
            Button { askAI(searchText) } label: {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "sparkles")
                        .font(.body)
                        .foregroundStyle(skin.accentColor)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ask AI \u{201C}\(searchText)\u{201D}")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(skin.resolvedTextPrimary)
                            .lineLimit(1)
                        Text("Generate custom optimization from your prompt")
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedTextSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, DS.Spacing.xs)
                .padding(.horizontal, DS.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Spacing.sm)
    }

    // MARK: - Footer

    private var footerHints: some View {
        HStack(spacing: DS.Spacing.md) {
            hint("↵", "run")
            hint("↑↓", "navigate")
            hint("→", "compose")
            hint("tab", "all")
            Spacer()
            hint("esc", "close")
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.sm)
        .padding(.bottom, DS.Spacing.xs)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption2.monospaced())
                .foregroundStyle(skin.resolvedTextSecondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(skin.resolvedTextTertiary.opacity(0.35), lineWidth: 0.5)
                )
            Text(label)
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextTertiary)
        }
    }

    // MARK: - Status Views

    private func statusView(_ label: String) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "hourglass")
                .font(.largeTitle)
                .foregroundStyle(skin.accentColor)
                .symbolEffect(.pulse, isActive: true)
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(skin.resolvedTextPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
    }

    private func appliedView(_ events: [EventInfo]) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(skin.resolvedSuccessColor)

            ForEach(events) { info in
                HStack(spacing: DS.Spacing.xs) {
                    Text(info.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .lineLimit(1)
                    Text(info.timeRange)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(skin.accentColor)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xl)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(skin.resolvedWarningColor)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(skin.resolvedTextPrimary)
                .multilineTextAlignment(.center)
            HStack(spacing: DS.Spacing.sm) {
                Button("Try again") {
                    withAnimation(DS.Animation.quick) { phase = .picking; aiError = nil }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(skin.accentColor)
                .buttonStyle(.plain)
                Button("Close") { onDismiss() }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
    }

    // MARK: - Actions

    private func handleSubmit() {
        if filtered.isEmpty && !searchText.isEmpty {
            askAI(searchText)
        } else if !filtered.isEmpty {
            let idx = min(selectedIndex, filtered.count - 1)
            runRequest(composedRequest ?? filtered[idx])
        }
    }

    private func runRequest(_ request: OptimizationRequest) {
        // Block if hard conflicts exist
        if IntentConflictDetector.hasErrors(request.intents) {
            revalidate(request)
            return
        }

        Haptics.tap()
        var working = request
        if let seedEvent {
            working = working.withEventContext(seedEvent)
        }

        phase = .working("Optimizing...")

        Task {
            let result = await optimizerService.executeRequest(working, reminderService: reminderService)

            // Record for learning
            optimizerService.backlogService.flatMap { _ in
                // IntentLearner recording would go here
            }

            await MainActor.run {
                switch result {
                case .success, .partialSuccess:
                    guard !optimizerService.scenarios.isEmpty else {
                        phase = .failed("No valid schedule found")
                        return
                    }
                    optimizerService.applyScenario(at: 0, to: reminderService)

                    let fmt = DateFormatter()
                    fmt.setLocalizedDateFormatFromTemplate("H:mm")
                    let infos = optimizerService.scenarios[0].genes.prefix(3).map { gene in
                        EventInfo(
                            id: gene.eventId,
                            title: gene.title,
                            timeRange: "\(fmt.string(from: gene.startTime))–\(fmt.string(from: gene.endTime))"
                        )
                    }
                    phase = .applied(infos)

                    onApplied(request) {
                        optimizerService.undoLast(reminderService: reminderService)
                    }

                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        onDismiss()
                    }

                case .noEventsToOptimize:
                    phase = .failed("Nothing to optimize — add tasks first")

                case .infeasible(let reason, _):
                    phase = .failed(reason)
                }
            }
        }
    }

    private func askAI(_ prompt: String) {
        guard agentService.isConfigured else {
            aiError = "Add API key in Settings → Assistant"
            return
        }
        Haptics.tap()
        phase = .working("Thinking...")
        Task {
            let result = await agentService.generateRequest(from: prompt)
            await MainActor.run {
                switch result {
                case .success(let request): runRequest(request)
                case .failure(let error): phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func refreshPreview() {
        dryRunTask?.cancel()
        guard let top = filtered.first, top.isCreative || top.findSlotOnly else { return }
        dryRunTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            var working = top
            working.speed = .quick
            working.maxScenarios = 1
            let genes = await optimizerService.executeDryRun(working, reminderService: reminderService)
            guard !Task.isCancelled else { return }
            if let genes, !genes.isEmpty {
                let fmt = DateFormatter()
                fmt.setLocalizedDateFormatFromTemplate("H:mm")
                dryRunPreview = genes.prefix(2).map {
                    "\($0.title) \(fmt.string(from: $0.startTime))–\(fmt.string(from: $0.endTime))"
                }.joined(separator: " · ")
            }
        }
    }

    // MARK: - Keyboard

    @ViewBuilder
    private var shortcuts: some View {
        Group {
            Button("All") { withAnimation(DS.Animation.quick) { showAll.toggle() } }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Close") { onDismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}
