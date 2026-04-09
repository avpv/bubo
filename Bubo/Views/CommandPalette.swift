import SwiftUI

// MARK: - Command Palette
//
// The single entry point for all schedule-optimization actions.
// Replaces OptimizerView, IntentPickerView, RecipeConfigSheet and AgentInputView.
//
// Design principles (Birman):
//  - One input field, one action, one Undo — no phases, no modals, no Apply button.
//  - Main input is a text field that searches across all recipes AND acts as the
//    AI prompt fallback when nothing matches.
//  - Top suggestion is visually prominent (card) with a schedule-aware preview
//    showing what will happen to YOUR schedule, not a generic description.
//  - Enter applies the top suggestion immediately, closes the palette, and shows
//    an Undo toast — the single feedback source (no redundant inline confirmation).
//  - ↑/↓ navigate, → expands parameter pills inline, Tab toggles "All recipes".
//  - Inline event picker replaces dead-end "Pick an event" text — no flow breaks.
//  - Expanding params pre-fills defaults so the user sees what will happen.
//
// The palette is shown as an inline overlay on top of the current popover
// content so the user never loses sight of the schedule underneath.

struct CommandPalette: View {
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var optimizerService: OptimizerService
    var reminderService: ReminderService
    var agentService: AgentService

    /// Optional event pre-selected by the caller (e.g. event context menu).
    /// When set, only recipes that apply to this event are shown.
    var seedEvent: CalendarEvent? = nil

    /// Optional free slot pre-selected by the caller (e.g. FreeSlotRow +).
    /// When set, only creative recipes that fit within the slot are shown.
    var seedSlotMinutes: Int? = nil

    /// Optional recipe to open pre-selected (e.g. from a smart banner tap).
    var seedPreset: OptimizationRequest? = nil

    /// Called when the palette wants to dismiss itself.
    var onDismiss: () -> Void
    /// Called after a recipe has been applied, so the host can show an Undo toast.
    var onApplied: (_ recipe: OptimizationRequest, _ undo: @escaping () -> Void) -> Void

    // MARK: State

    @State private var searchText: String = ""
    @State private var selectedIndex: Int = 0
    @State private var expandedRecipeId: String? = nil
    @State private var localParams: [String: [String: Any]] = [:]
    @State private var showAllRecipes: Bool = false
    @State private var phase: Phase = .picking
    @State private var appliedRecipeName: String = ""
    @State private var aiError: String? = nil
    /// Async dry-run preview for the top suggestion — shows concrete event times
    /// computed by actually running the recipe through the GA (fast config).
    @State private var dryRunPreview: String? = nil
    @State private var dryRunTask: Task<Void, Never>? = nil
    @FocusState private var isSearchFocused: Bool

    private enum Phase: Equatable {
        case picking
        case working(String)    // status label, e.g. "Optimizing…"
        case applied([AppliedEventInfo])  // brief confirmation with concrete data
        case failed(String)     // error message + optional retry
    }

    /// Info about a single event created/placed by a recipe, shown in the
    /// applied confirmation phase so the user sees exactly what changed.
    struct AppliedEventInfo: Equatable, Identifiable {
        let id: String
        let title: String
        let timeRange: String   // e.g. "14:30–15:30"
    }

    // MARK: - Context

    /// Recipes surfaced as contextual suggestions when the search field is empty.
    /// Order: banner-worthy suggestions → usage-based top recipes → curated defaults.
    private var contextualSuggestions: [OptimizationRequest] {
        var result: [OptimizationRequest] = []

        // 1. Suggestion engine recommendations
        if let suggestion = optimizerService.suggestionEngine?.suggestion {
            result.append(suggestion.request)
        }

        // 2. Time-of-day defaults
        for preset in defaultSuggestionsByTimeOfDay {
            if !result.contains(where: { $0.name == preset.name }) {
                result.append(preset)
            }
            if result.count >= 5 { return result }
        }

        return result
    }

    private var defaultSuggestionsByTimeOfDay: [OptimizationRequest] {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<11:   return [.organizeDay, .findFocus(), .scheduleBacklog]
        case 11..<15:  return [.findFocus(), .scheduleBacklog, .lowEnergyDay]
        case 15..<19:  return [.scheduleBacklog, .organizeDay, .planWeek]
        default:       return [.planWeek, .organizeDay, .scheduleBacklog]
        }
    }

    /// The flat list that the search field filters.
    /// Empty search → contextual suggestions. Typed search → matching recipes.
    /// Seed event/slot → narrowed to applicable recipes.
    private var filteredRecipes: [OptimizationRequest] {
        let all: [OptimizationRequest] = {
            if let seedEvent {
                return IntentPresets.all
                    .sorted { ($0.name ?? "") < ($1.name ?? "") }
            }
            if let minutes = seedSlotMinutes {
                return IntentPresets.all
                    .sorted { ($0.name ?? "") < ($1.name ?? "") }
            }
            return IntentPresets.all
        }()

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            if seedEvent == nil && seedSlotMinutes == nil {
                return contextualSuggestions
            }
            return Array(all.prefix(8))
        }
        return all.filter { $0.matchesSearch(query) }
            .sorted { lhs, rhs in
                // Name hits first, then description/category hits.
                let lName = (lhs.name ?? "").lowercased().contains(query.lowercased())
                let rName = (rhs.name ?? "").lowercased().contains(query.lowercased())
                if lName != rName { return lName }
                return lhs.name < rhs.name
            }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Scrim — dims the content behind the palette but keeps it visible.
            Rectangle()
                .fill(Color.black.opacity(0.25))
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .transition(.opacity)
                .accessibilityLabel("Close command palette")

            paletteCard
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.xl)
                .frame(maxHeight: .infinity, alignment: .top)

            // Invisible keyboard shortcut host — has to live in the hierarchy
            // so SwiftUI picks up the shortcut modifiers.
            keyboardShortcuts
        }
        .onAppear {
            isSearchFocused = true
            if let seed = seedPreset {
                expandedRecipeId = seed.id
                prepopulateDefaults(for: seed)
                if let idx = filteredRecipes.firstIndex(where: { $0.id == seed.id }) {
                    selectedIndex = idx
                }
            }
            startDryRunPreview()
        }
        .onDisappear {
            dryRunTask?.cancel()
        }
    }

    // MARK: - Card

    private var paletteCard: some View {
        VStack(spacing: 0) {
            searchField
            SkinSeparator()
            resultsScroll
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .fill(.ultraThickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(skin.accentColor.opacity(0.25), lineWidth: DS.Border.standard)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 18, y: 8)
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            // → expands/collapses the selected recipe's params.
            // Only handle when the search field is empty — otherwise let
            // the TextField use → for normal cursor movement.
            guard searchText.isEmpty else { return .ignored }
            let recipes = filteredRecipes
            guard !recipes.isEmpty else { return .ignored }
            let idx = min(selectedIndex, recipes.count - 1)
            let recipe = recipes[idx]
            withAnimation(DS.Animation.quick) {
                if expandedRecipeId == recipe.id {
                    expandedRecipeId = nil
                } else {
                    expandedRecipeId = recipe.id
                }
            }
            return .handled
        }
        .onKeyPress(.tab) {
            // Tab toggles "All recipes" flat list.
            withAnimation(DS.Animation.quick) {
                showAllRecipes.toggle()
            }
            return .handled
        }
        .transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                )
        )
    }

    private func moveSelection(by delta: Int) {
        let count = filteredRecipes.count
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: iconForCurrentPhase)
                .font(.body)
                .foregroundStyle(iconColorForCurrentPhase)
                .symbolEffect(.pulse, isActive: isBusy)
                .frame(width: 18)
                .accessibilityHidden(true)

            TextField(placeholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(.headline)
                .focused($isSearchFocused)
                .disabled(isBusy)
                .onSubmit { handlePrimaryAction() }
                .onChange(of: searchText) {
                    selectedIndex = 0
                    expandedRecipeId = nil
                    aiError = nil
                }
                .accessibilityLabel("Command palette search")

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
                .accessibilityLabel("Clear")
            }

            keyHintBadge
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.md)
    }

    private var iconForCurrentPhase: String {
        switch phase {
        case .picking:       return "sparkles"
        case .working:       return "hourglass"
        case .applied:       return "checkmark.circle.fill"
        case .failed:        return "exclamationmark.triangle.fill"
        }
    }

    private var iconColorForCurrentPhase: Color {
        switch phase {
        case .picking:       return skin.accentColor
        case .working:       return skin.accentColor
        case .applied:       return skin.resolvedSuccessColor
        case .failed:        return skin.resolvedWarningColor
        }
    }

    private var isBusy: Bool {
        switch phase {
        case .working, .applied: return true
        default: return false
        }
    }

    private var placeholder: String {
        if seedEvent != nil { return "Change this event…" }
        if let m = seedSlotMinutes { return "Fill \(m) min free slot…" }
        return "Find focus time, plan a day, ask AI…"
    }

    private var keyHintBadge: some View {
        HStack(spacing: 2) {
            Text("⌘K")
                .font(.caption2.monospaced())
                .foregroundStyle(skin.resolvedTextTertiary)
        }
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(skin.resolvedTextTertiary.opacity(0.35), lineWidth: 0.5)
        )
        .opacity(isBusy ? 0.3 : 1.0)
        .accessibilityHidden(true)
    }

    // MARK: - Results

    private var resultsScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch phase {
                case .picking:
                    pickingContent
                case .working(let label):
                    statusView(icon: "hourglass", text: label, color: skin.accentColor)
                case .applied(let events):
                    appliedView(events: events)
                case .failed(let message):
                    failedView(message: message)
                }
            }
            .padding(.vertical, DS.Spacing.sm)
        }
        .frame(maxHeight: 420)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var pickingContent: some View {
        if showAllRecipes && searchText.isEmpty {
            allRecipesSection
        } else {
            contextStrip
            recipeList

            // Intent composer — add/remove individual intents
            if let selected = composerRequest {
                intentComposer(for: selected)
            }

            footerHints
        }

        if let aiError {
            Text(aiError)
                .font(.caption)
                .foregroundStyle(skin.resolvedWarningColor)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.xs)
        }
    }

    // The request being composed (expanded preset or custom)
    private var composerRequest: OptimizationRequest? {
        guard let id = expandedRecipeId else { return nil }
        return filteredRecipes.first { $0.id == id }
    }

    // MARK: - Intent Composer

    @ViewBuilder
    @State private var composerPreview: String? = nil
    @State private var composerPreviewTask: Task<Void, Never>? = nil

    private func intentComposer(for request: OptimizationRequest) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Active intents (removable)
            Text("Active intents")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(skin.resolvedTextTertiary)
                .tracking(0.5)

            FlowLayout(spacing: DS.Spacing.xs) {
                ForEach(Array(request.intents.enumerated()), id: \.offset) { index, intent in
                    intentChip(intent.label, isActive: true) {
                        var modified = request
                        modified.removeIntent(at: index)
                        replaceExpandedPreset(modified)
                        refreshComposerPreview(modified)
                    }
                }
            }

            // Available intents (addable)
            let available = request.availableIntents
            if !available.isEmpty {
                Text("Add")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .tracking(0.5)
                    .padding(.top, DS.Spacing.xs)

                FlowLayout(spacing: DS.Spacing.xs) {
                    ForEach(Array(available.prefix(12).enumerated()), id: \.offset) { _, intent in
                        intentChip(intent.label, isActive: false) {
                            var modified = request
                            modified.add(intent)
                            replaceExpandedPreset(modified)
                            refreshComposerPreview(modified)
                        }
                    }
                }
            }

            // Live preview — shows what will happen when you run this
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
                .padding(.top, DS.Spacing.xs)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(skin.accentColor.opacity(0.04))
        )
        .padding(.horizontal, DS.Spacing.sm)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .onAppear { refreshComposerPreview(request) }
    }

    /// Refresh the live preview asynchronously via a fast dry-run.
    private func refreshComposerPreview(_ request: OptimizationRequest) {
        composerPreviewTask?.cancel()
        guard request.isCreative || request.findSlotOnly else {
            // Non-creative requests: show a static description
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
                let descriptions = genes.prefix(3).map { gene in
                    "\(gene.title) \(fmt.string(from: gene.startTime))–\(fmt.string(from: gene.endTime))"
                }
                composerPreview = descriptions.joined(separator: " · ")
            } else {
                composerPreview = "No feasible slot found"
            }
        }
    }

    private func intentChip(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.caption2.weight(.medium))
                if isActive {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(isActive ? Color.white : skin.resolvedTextPrimary)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isActive ? skin.accentColor : skin.accentColor.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
    }

    /// Replace the expanded preset in the filtered list with a modified version.
    private func replaceExpandedPreset(_ modified: OptimizationRequest) {
        // Store modified version for the next run
        // Since presets are static, we store modifications as a local override
        expandedModifiedRequest = modified
    }

    @State private var expandedModifiedRequest: OptimizationRequest? = nil

    // MARK: - Context Strip

    @ViewBuilder
    private var contextStrip: some View {
        if searchText.isEmpty {
            HStack(spacing: DS.Spacing.xs) {
                Text(contextSummary)
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.xs)
        }
    }

    private var contextSummary: String {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        let now = fmt.string(from: Date())
        if let seedEvent {
            return "Change \u{201C}\(seedEvent.title)\u{201D}"
        }
        if let minutes = seedSlotMinutes {
            return "Free slot · \(minutes) min"
        }
        return "Now \(now) · tap a suggestion or type to search"
    }

    // MARK: - Recipe List

    private var recipeList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(filteredRecipes.enumerated()), id: \.element.id) { index, recipe in
                RecipeRow(
                    recipe: recipe,
                    isSelected: index == selectedIndex,
                    isExpanded: expandedRecipeId == recipe.id,
                    isTopSuggestion: index == 0 && searchText.isEmpty && seedEvent == nil && seedSlotMinutes == nil,
                    previewText: (index == 0 && dryRunPreview != nil)
                        ? dryRunPreview
                        : recipe.schedulePreview(
                            reminderService: reminderService,
                            workingHours: optimizerService.workingHours
                        ),
                    onTap: {
                        selectedIndex = index
                        runRecipe(recipe)
                    },
                    onExpand: {
                        withAnimation(DS.Animation.quick) {
                            if expandedRecipeId == recipe.id {
                                expandedRecipeId = nil
                            } else {
                                expandedRecipeId = recipe.id
                                prepopulateDefaults(for: recipe)
                            }
                        }
                    }
                )
                .onHover { hovering in
                    if hovering { selectedIndex = index }
                }
                .id("recipe-\(recipe.id)")
            }

            if filteredRecipes.isEmpty {
                emptyResultsRow
            }

            askAIRow
        }
        .padding(.horizontal, DS.Spacing.sm)
    }

    // MARK: - Footer Hints

    private var footerHints: some View {
        HStack(spacing: DS.Spacing.md) {
            hintKey("↵", "run")
            hintKey("↑↓", "navigate")
            hintKey("→", "tweak")
            hintKey("tab", "all")
            Spacer()
            hintKey("esc", "close")
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.sm)
        .padding(.bottom, DS.Spacing.xs)
    }

    private func hintKey(_ key: String, _ label: String) -> some View {
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

    // MARK: - All Recipes Flat List

    private var allRecipesSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            ForEach(IntentPresets.allCategories) { category in
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .tracking(0.5)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.top, DS.Spacing.sm)

                    ForEach(category.presets) { recipe in
                        RecipeRow(
                            recipe: recipe,
                            isSelected: false,
                            isExpanded: expandedRecipeId == recipe.id,
                            isTopSuggestion: false,
                            previewText: nil,
                            availableEvents: reminderService.localEvents.filter { $0.isUpcoming },
                            paramValue: { paramId in localParams[recipe.id]?[paramId] },
                            setParamValue: { paramId, value in
                                var dict = localParams[recipe.id] ?? [:]
                                dict[paramId] = value
                                localParams[recipe.id] = dict
                            },
                            onTap: { runRecipe(recipe) },
                            onExpand: {
                                withAnimation(DS.Animation.quick) {
                                    if expandedRecipeId == recipe.id {
                                        expandedRecipeId = nil
                                    } else {
                                        expandedRecipeId = recipe.id
                                        prepopulateDefaults(for: recipe)
                                    }
                                }
                            }
                        )
                    }
                }
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
    }

    // MARK: - Empty & AI rows

    private var emptyResultsRow: some View {
        VStack(spacing: DS.Spacing.xs) {
            Text("No recipes match \u{201C}\(searchText)\u{201D}")
                .font(.caption)
                .foregroundStyle(skin.resolvedTextSecondary)
            Text("Press ↵ to ask AI instead")
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.lg)
    }

    @ViewBuilder
    private var askAIRow: some View {
        if !searchText.isEmpty && agentService.isConfigured {
            Divider()
                .padding(.vertical, DS.Spacing.xs)
            Button {
                askAI(with: searchText)
            } label: {
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
                        Text("Generate a custom recipe from your prompt")
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedTextSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.vertical, DS.Spacing.xs)
                .padding(.horizontal, DS.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Status views

    private func statusView(icon: String, text: String, color: Color) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: isBusy)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(skin.resolvedTextPrimary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
    }

    /// Brief inline confirmation showing exactly what was created/placed.
    /// Connects action → result in the user's mind (Birman: show the consequence).
    private func appliedView(events: [AppliedEventInfo]) -> some View {
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

            if events.count < (optimizerService.scenarios.first?.genes.count ?? 0) {
                Text("+\(optimizerService.scenarios.first!.genes.count - events.count) more")
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xl)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(skin.resolvedWarningColor)

            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(skin.resolvedTextPrimary)
                .multilineTextAlignment(.center)

            HStack(spacing: DS.Spacing.sm) {
                Button {
                    withAnimation(DS.Animation.quick) {
                        phase = .picking
                        aiError = nil
                    }
                } label: {
                    Text("Try again")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(skin.accentColor)
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                } label: {
                    Text("Close")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
    }

    // MARK: - Dry-Run Preview

    /// Asynchronously runs the top suggestion through a fast GA to get concrete
    /// event placement, then formats "Focus Time 14:30–15:30" as the preview.
    /// Only runs for the top-1 recipe (the card) to avoid burning CPU.
    private func startDryRunPreview() {
        dryRunTask?.cancel()
        dryRunPreview = nil

        guard let recipe = filteredRecipes.first else { return }
        // Only creative/findSlotOnly recipes benefit from dry-run — organizing
        // recipes are too slow and the heuristic preview is good enough.
        guard recipe.findSlotOnly || recipe.isCreative else { return }

        dryRunTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            var working = recipe
            if let seedEvent {
                working = working.withEventContext(seedEvent)
            }
            working.speed = .quick
            working.maxScenarios = 1

            let result = await optimizerService.executeDryRun(
                working,
                reminderService: reminderService
            )
            guard !Task.isCancelled else { return }

            if let genes = result {
                let fmt = DateFormatter()
                fmt.setLocalizedDateFormatFromTemplate("H:mm")
                let descriptions = genes.prefix(2).map { gene in
                    "\(gene.title) \(fmt.string(from: gene.startTime))–\(fmt.string(from: gene.endTime))"
                }
                let suffix = genes.count > 2 ? " +\(genes.count - 2)" : ""
                dryRunPreview = descriptions.joined(separator: " · ") + suffix
            }
        }
    }

    // MARK: - Prepopulate Defaults

    /// No-op: intents don't use param values. Kept for call-site compatibility.
    private func prepopulateDefaults(for recipe: OptimizationRequest) {
        // Intent composer handles customization directly.
        if false {
            localParams[recipe.id] = defaults
        }
    }

    // MARK: - Actions

    private func handlePrimaryAction() {
        if filteredRecipes.isEmpty && !searchText.isEmpty {
            askAI(with: searchText)
            return
        }
        guard !filteredRecipes.isEmpty else { return }
        let idx = min(selectedIndex, filteredRecipes.count - 1)
        runRecipe(filteredRecipes[idx])
    }

    private func runRecipe(_ recipe: OptimizationRequest) {
        Haptics.tap()
        // Use the composer-modified version if available, otherwise original
        var working = expandedModifiedRequest?.id == recipe.id
            ? expandedModifiedRequest!
            : recipe

        if let seedEvent {
            working = working.withEventContext(seedEvent)
        }

        phase = .working("Optimizing…")
        appliedRecipeName = (recipe.name ?? "Optimize")

        Task {
            let result = await optimizerService.executeRequest(
                working,
                reminderService: reminderService
            )
            await MainActor.run {
                switch result {
                case .success, .partialSuccess:
                    guard !optimizerService.scenarios.isEmpty else {
                        phase = .failed("No valid schedule found")
                        return
                    }
                    let scenario = optimizerService.scenarios[0]
                    optimizerService.applyScenario(at: 0, to: reminderService)

                    // Show brief inline confirmation with concrete event details
                    // so the user's brain connects action → result.
                    let fmt = DateFormatter()
                    fmt.setLocalizedDateFormatFromTemplate("H:mm")
                    let eventInfos = scenario.genes.prefix(3).map { gene in
                        AppliedEventInfo(
                            id: gene.eventId,
                            title: gene.title,
                            timeRange: "\(fmt.string(from: gene.startTime))–\(fmt.string(from: gene.endTime))"
                        )
                    }
                    phase = .applied(eventInfos)

                    // Offer undo via the host toast.
                    onApplied(recipe, {
                        optimizerService.undoLast(reminderService: reminderService)
                    })

                    // Auto-dismiss after 1 second — enough to read but not to wait.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        dismiss()
                    }

                case .noEventsToOptimize:
                    phase = .failed("Nothing to optimize — add events first")

                case .infeasible(let reason, _):
                    phase = .failed(reason)
                }
            }
        }
    }

    private func askAI(with prompt: String) {
        guard agentService.isConfigured else {
            aiError = "Add an API key in Settings → Assistant to use AI"
            return
        }
        Haptics.tap()
        phase = .working("Thinking…")
        appliedRecipeName = "AI recipe"

        Task {
            let result = await agentService.generateRequest(from: prompt)
            await MainActor.run {
                switch result {
                case .success(let recipe):
                    runRecipe(recipe)
                case .failure(let error):
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func dismiss() {
        onDismiss()
    }

    // MARK: - Keyboard

    /// Keyboard shortcuts rendered as invisible buttons so SwiftUI can pick them up.
    /// Arrow keys and Tab are handled via `.onKeyPress` on the palette card.
    /// Esc and ⌘⇧A are handled here as fallbacks.
    @ViewBuilder
    var keyboardShortcuts: some View {
        Group {
            Button("Toggle all recipes") {
                withAnimation(DS.Animation.quick) {
                    showAllRecipes.toggle()
                }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Recipe Row

private struct RecipeRow: View {
    @Environment(\.activeSkin) private var skin

    let recipe: OptimizationRequest
    let isSelected: Bool
    let isExpanded: Bool
    let isTopSuggestion: Bool
    let previewText: String?
    let onTap: () -> Void
    let onExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Spacing.sm) {
                // Main click target — runs the recipe.
                Button(action: onTap) {
                    HStack(spacing: DS.Spacing.sm) {
                        Circle()
                            .fill(DS.Colors.categoryPalette[recipe.categoryColorIndex])
                            .frame(
                                width: isTopSuggestion ? 10 : DS.Size.recipeDotSize,
                                height: isTopSuggestion ? 10 : DS.Size.recipeDotSize
                            )
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: isTopSuggestion ? 2 : 1) {
                            Text((recipe.name ?? "Optimize"))
                                .font(isTopSuggestion ? .headline.weight(.semibold) : .subheadline.weight(isSelected ? .semibold : .medium))
                                .foregroundStyle(skin.resolvedTextPrimary)
                                .lineLimit(1)

                            // Preview text replaces the generic description
                            // when schedule-aware info is available (Birman: information > description).
                            if let preview = previewText {
                                Text(preview)
                                    .font(isTopSuggestion ? .caption : .caption2)
                                    .foregroundStyle(skin.accentColor.opacity(0.85))
                                    .lineLimit(1)
                            } else {
                                Text((recipe.description ?? recipe.intents.map(\.label).joined(separator: " · ")))
                                    .font(.caption2)
                                    .foregroundStyle(skin.resolvedTextSecondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: DS.Spacing.sm)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Expand chevron — opens intent composer
                Button(action: onExpand) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse" : "Customize intents")
            }
            .padding(.vertical, isTopSuggestion ? DS.Spacing.sm : DS.Spacing.xs)
            .padding(.horizontal, DS.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isTopSuggestion
                            ? skin.accentColor.opacity(isSelected ? 0.18 : 0.08)
                            : (isSelected ? skin.accentColor.opacity(0.14) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isTopSuggestion ? skin.accentColor.opacity(0.20) : Color.clear,
                        lineWidth: 0.5
                    )
            )

            // Intent summary when expanded (composer is in the parent view)
            if isExpanded {
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(Array(recipe.intents.prefix(5).enumerated()), id: \.offset) { _, intent in
                        Text(intent.label)
                            .font(.caption2)
                            .foregroundStyle(skin.accentColor.opacity(0.7))
                            .padding(.horizontal, DS.Spacing.xs)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(skin.accentColor.opacity(0.08)))
                    }
                    if recipe.intents.count > 5 {
                        Text("+\(recipe.intents.count - 5)")
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedTextTertiary)
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.xs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // Legacy param UI removed — replaced by intent composer in parent view.
    // RecipeRow now shows intent summary chips instead.

    private func pill(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(isActive ? Color.white : skin.resolvedTextPrimary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(isActive ? skin.accentColor : skin.accentColor.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
    }
}
