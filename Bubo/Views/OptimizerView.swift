import SwiftUI

// MARK: - Schedule Assistant View (Rewritten)

/// Container view for the recipe-based optimization flow.
/// Internal state machine: pick → configure → optimizing → results.
struct OptimizerView: View {
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var optimizerService: OptimizerService
    var reminderService: ReminderService
    var agentService: AgentService
    var onBack: () -> Void
    var onAddTasks: (() -> Void)? = nil

    @State private var phase: Phase = .picking
    @State private var selectedRecipe: ScheduleRecipe? = nil
    @State private var isAnimatingSpinner = false
    @State private var lastParamValues: [String: Any] = [:]

    enum Phase: Equatable {
        case picking
        case agentInput
        case configuring
        case optimizing
        case results
        case error(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.picking, .picking): return true
            case (.agentInput, .agentInput): return true
            case (.configuring, .configuring): return true
            case (.optimizing, .optimizing): return true
            case (.results, .results): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Group {
                switch phase {
                case .picking:
                    IntentPickerView(
                        optimizerService: optimizerService,
                        hasLocalEvents: !reminderService.localEvents.filter(\.isUpcoming).isEmpty,
                        onSelectRecipe: handleRecipeSelected,
                        onAskAI: handleAskAI
                    )

                case .agentInput:
                    AgentInputView(
                        agentService: agentService,
                        onRecipeGenerated: handleAgentRecipe,
                        onCancel: { resetToPicking() }
                    )

                case .configuring:
                    if let recipe = selectedRecipe {
                        RecipeConfigSheet(
                            recipe: recipe,
                            reminderService: reminderService,
                            onExecute: handleExecute,
                            onCancel: { resetToPicking() },
                            onAddTasks: onAddTasks,
                            onSwitchRecipe: { newRecipe in
                                handleRecipeSelected(newRecipe)
                            }
                        )
                    }

                case .optimizing:
                    optimizingView

                case .results:
                    if let recipe = selectedRecipe {
                        IntentResultView(
                            recipe: recipe,
                            optimizerService: optimizerService,
                            reminderService: reminderService,
                            onBack: { resetToPicking() },
                            onDone: onBack
                        )
                    }

                case .error(let message):
                    errorView(message)
                }
            }
            .animation(
                reduceMotion ? DS.Animation.quick : DS.Animation.smoothSpring,
                value: phase
            )
        }
        .onAppear {
            // If a recipe was pre-set (from context menu or QuickAddTasks),
            // jump directly to results or config
            if let recipe = optimizerService.activeRecipe {
                selectedRecipe = recipe
                if !optimizerService.scenarios.isEmpty {
                    phase = .results
                } else if recipe.params.isEmpty {
                    handleExecute(recipe, [:])
                } else {
                    phase = .configuring
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        PopoverHeader(
            title: "Schedule Assistant",
            showBack: true,
            onBack: {
                switch phase {
                case .picking:
                    onBack()
                case .agentInput, .configuring, .error:
                    resetToPicking()
                case .optimizing:
                    break // can't go back while optimizing
                case .results:
                    resetToPicking()
                }
            }
        )
    }

    // MARK: - Optimizing View

    private var optimizingView: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

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
                Image(systemName: selectedRecipe?.icon ?? "wand.and.stars")
                    .font(.system(size: 20))
                    .foregroundStyle(skin.accentColor)
                    .symbolEffect(.pulse)
            }

            VStack(spacing: DS.Spacing.xs) {
                Text(selectedRecipe?.isCreative == true ? "Finding best time…" : "Optimizing schedule…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextPrimary)
                if let recipe = selectedRecipe {
                    Text(recipe.description)
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Spacing.lg)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error View

    private var isNoEventsError: Bool {
        if case .error(let msg) = phase {
            return msg.contains("No events")
        }
        return false
    }

    /// Recipes that create new events (don't require existing tasks).
    private var creativeRecipes: [ScheduleRecipe] {
        RecipeCatalog.quickActions.filter { $0.isCreative }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

            if isNoEventsError {
                // Specific empty-state for "no events" — guide the user
                Image(systemName: "tray")
                    .font(.system(size: 36))
                    .foregroundStyle(skin.resolvedTextTertiary)

                VStack(spacing: DS.Spacing.xs) {
                    Text("Nothing to organize yet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(skin.resolvedTextPrimary)
                    Text("This recipe rearranges existing tasks.\nAdd some first, or try a recipe that creates new blocks.")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Spacing.lg)
                }

                VStack(spacing: DS.Spacing.sm) {
                    if onAddTasks != nil {
                        Button {
                            Haptics.tap()
                            onAddTasks?()
                        } label: {
                            Label("Add tasks", systemImage: "plus")
                        }
                        .buttonStyle(.action(role: .primary, size: .compact))
                    }

                    Button("Browse recipes") {
                        Haptics.tap()
                        resetToPicking()
                    }
                    .buttonStyle(.action(role: .secondary, size: .compact))
                }

                // Suggest recipes that create events
                if !creativeRecipes.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        Text("Or try one of these")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(skin.resolvedTextTertiary)

                        ForEach(creativeRecipes) { recipe in
                            RecipeCardView(recipe: recipe, style: .list, onTap: handleRecipeSelected)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                }
            } else {
                // Actionable error with context
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 36))
                    .foregroundStyle(skin.resolvedWarningColor)

                VStack(spacing: DS.Spacing.xs) {
                    Text("Couldn't fit it in")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(skin.resolvedTextPrimary)
                    Text(friendlyErrorMessage(message))
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Spacing.lg)
                }

                VStack(spacing: DS.Spacing.sm) {
                    // If the recipe has params, offer to go back and adjust
                    if let recipe = selectedRecipe, !recipe.params.isEmpty {
                        Button {
                            Haptics.tap()
                            phase = .configuring
                        } label: {
                            Label("Adjust settings", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.action(role: .primary, size: .compact))
                    }

                    Button("Try a different recipe") {
                        Haptics.tap()
                        resetToPicking()
                    }
                    .buttonStyle(.action(role: .secondary, size: .compact))
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Convert technical error messages into user-friendly guidance.
    private func friendlyErrorMessage(_ raw: String) -> String {
        if raw.contains("hard constraints") || raw.contains("Cannot satisfy") {
            if let recipe = selectedRecipe, recipe.isCreative {
                return "Your schedule is too packed to fit this block. Try a shorter duration or a different day."
            }
            return "Not enough room to rearrange with current constraints. Try fewer tasks or a wider time range."
        }
        return raw
    }

    // MARK: - Actions

    private func handleRecipeSelected(_ recipe: ScheduleRecipe) {
        Haptics.tap()
        selectedRecipe = recipe

        if recipe.params.isEmpty {
            // No configuration needed — execute immediately
            handleExecute(recipe, [:])
        } else {
            // Show configuration sheet
            phase = .configuring
        }
    }

    private func handleAskAI() {
        Haptics.tap()
        phase = .agentInput
    }

    private func handleAgentRecipe(_ recipe: ScheduleRecipe) {
        Haptics.tap()
        selectedRecipe = recipe
        // Agent-generated recipes have no params — execute immediately
        handleExecute(recipe, [:])
    }

    private func handleExecute(_ recipe: ScheduleRecipe, _ paramValues: [String: Any]) {
        selectedRecipe = recipe
        lastParamValues = paramValues
        phase = .optimizing

        Task {
            let result = await optimizerService.executeRecipe(
                recipe,
                paramValues: paramValues,
                reminderService: reminderService
            )

            switch result {
            case .success, .partialSuccess:
                phase = .results
            case .noEventsToOptimize:
                phase = .error("No events to optimize. Add some tasks first.")
            case .infeasible(let reason):
                phase = .error(reason)
            }
        }
    }

    private func resetToPicking() {
        phase = .picking
        selectedRecipe = nil
        optimizerService.scenarios = []
    }
}
