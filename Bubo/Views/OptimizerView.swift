import SwiftUI

// MARK: - Schedule Assistant View

/// Container view for the recipe-based optimization flow.
/// Internal state machine: pick → recipeDetail (config + optimize + results inline).
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

    enum Phase: Equatable {
        case picking
        case agentInput
        case recipeDetail
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

                case .recipeDetail:
                    if let recipe = selectedRecipe {
                        RecipeConfigSheet(
                            recipe: recipe,
                            reminderService: reminderService,
                            onExecute: { _, _ in },
                            onCancel: { resetToPicking() },
                            onAddTasks: onAddTasks,
                            onSwitchRecipe: { newRecipe in
                                handleRecipeSelected(newRecipe)
                            },
                            optimizerService: optimizerService,
                            onDone: onBack
                        )
                    }
                }
            }
            .animation(
                reduceMotion ? DS.Animation.quick : DS.Animation.smoothSpring,
                value: phase
            )
        }
        .onAppear {
            // If a recipe was pre-set (from context menu or QuickAddTasks),
            // jump directly to recipeDetail
            if let recipe = optimizerService.activeRecipe {
                selectedRecipe = recipe
                phase = .recipeDetail
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
                case .agentInput, .recipeDetail:
                    resetToPicking()
                }
            }
        )
    }

    // MARK: - Actions

    private func handleRecipeSelected(_ recipe: ScheduleRecipe) {
        Haptics.tap()
        selectedRecipe = recipe
        phase = .recipeDetail
    }

    private func handleAskAI() {
        Haptics.tap()
        phase = .agentInput
    }

    private func handleAgentRecipe(_ recipe: ScheduleRecipe) {
        Haptics.tap()
        selectedRecipe = recipe
        phase = .recipeDetail
    }

    private func resetToPicking() {
        phase = .picking
        selectedRecipe = nil
        optimizerService.scenarios = []
    }
}
