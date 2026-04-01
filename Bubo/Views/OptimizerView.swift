import SwiftUI

// MARK: - Schedule Assistant View (Rewritten)

/// Container view for the recipe-based optimization flow.
/// Internal state machine: pick → configure → optimizing → results.
struct OptimizerView: View {
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var optimizerService: OptimizerService
    var reminderService: ReminderService
    var onBack: () -> Void

    @State private var phase: Phase = .picking
    @State private var selectedRecipe: ScheduleRecipe? = nil
    @State private var isAnimatingSpinner = false

    enum Phase: Equatable {
        case picking
        case configuring
        case optimizing
        case results
        case error(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.picking, .picking): return true
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
                        onSelectRecipe: handleRecipeSelected
                    )

                case .configuring:
                    if let recipe = selectedRecipe {
                        RecipeConfigSheet(
                            recipe: recipe,
                            onExecute: handleExecute,
                            onCancel: { resetToPicking() }
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
                case .configuring, .error:
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
                Text("Optimizing schedule…")
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

    private func errorView(_ message: String) -> some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(skin.resolvedWarningColor)

            VStack(spacing: DS.Spacing.xs) {
                Text("Couldn't optimize")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextPrimary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.lg)
            }

            Button("Try a different recipe") {
                Haptics.tap()
                resetToPicking()
            }
            .buttonStyle(.action(role: .primary, size: .compact))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func handleExecute(_ recipe: ScheduleRecipe, _ paramValues: [String: Any]) {
        selectedRecipe = recipe
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
