import SwiftUI

// MARK: - Intent Result View

/// Displays optimization results adapted to the recipe's `display` mode.
/// Handles: scenarios, confirmation, toast, dryRun.
struct IntentResultView: View {
    @Environment(\.activeSkin) private var skin
    let recipe: ScheduleRecipe
    var optimizerService: OptimizerService
    var reminderService: ReminderService
    let onBack: () -> Void
    let onDone: () -> Void

    @State private var selectedScenarioIndex = 0
    @State private var appliedIndex: Int? = nil

    private static let timeFormatter = DS.timeFormatter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch recipe.display {
            case .scenarios:
                scenariosView
            case .confirmation:
                confirmationView
            case .dryRun:
                dryRunView
            case .toast, .inline:
                // Handled externally (toast overlay / event list inline)
                confirmationView
            }

            Spacer(minLength: 0)
            SkinSeparator()
            footerActions
        }
    }

    // MARK: - Scenarios View

    private var scenariosView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                // Recipe header
                recipeHeader

                // Scenario count
                Text("Found \(optimizerService.scenarios.count) option(s)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(skin.resolvedTextPrimary)

                // Scenario picker
                if optimizerService.scenarios.count > 1 {
                    Picker("Option", selection: $selectedScenarioIndex) {
                        ForEach(0..<optimizerService.scenarios.count, id: \.self) { idx in
                            Text("Option \(idx + 1)").tag(idx)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Scenario detail
                if selectedScenarioIndex < optimizerService.scenarios.count {
                    scenarioDetail(optimizerService.scenarios[selectedScenarioIndex])
                }
            }
            .padding(DS.Spacing.lg)
        }
    }

    // MARK: - Confirmation View

    private var confirmationView: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(skin.accentColor)

            Text("Schedule adjusted")
                .font(.headline)
                .foregroundStyle(skin.resolvedTextPrimary)

            if let scenario = optimizerService.scenarios.first {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    ForEach(scenario.genes, id: \.eventId) { gene in
                        HStack(spacing: DS.Spacing.sm) {
                            Image(systemName: gene.isFocusBlock ? "brain.head.profile" : "calendar")
                                .font(.caption)
                                .foregroundStyle(skin.accentColor)
                            Text(gene.title)
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text(formatTimeRange(gene.startTime, gene.endTime))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(skin.resolvedTextSecondary)
                        }
                    }
                }
                .padding(DS.Spacing.md)
                .skinPlatter(skin)
                .skinPlatterDepth(skin)
                .padding(.horizontal, DS.Spacing.lg)
            }

            Spacer()
        }
    }

    // MARK: - Dry Run View

    private var dryRunView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                recipeHeader

                Label("Preview — no changes applied", systemImage: "eye")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(skin.resolvedWarningColor)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xs)
                    .background(skin.resolvedWarningColor.opacity(0.1))
                    .clipShape(Capsule())

                if let scenario = optimizerService.scenarios.first {
                    scenarioDetail(scenario)
                }
            }
            .padding(DS.Spacing.lg)
        }
    }

    // MARK: - Recipe Header

    private var recipeHeader: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: recipe.icon)
                .font(.title3)
                .foregroundStyle(skin.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextPrimary)
                Text(recipe.description)
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
            Spacer()
        }
    }

    // MARK: - Scenario Detail

    private func scenarioDetail(_ scenario: ScheduleScenario) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Fitness pill
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

            // Events list
            ForEach(scenario.genes, id: \.eventId) { gene in
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: gene.isFocusBlock ? "brain.head.profile" : "calendar")
                        .font(.caption)
                        .foregroundStyle(skin.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(gene.title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
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
                objectiveBreakdown(scenario.objectiveBreakdown)
            }

            // Warnings
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

    private func objectiveBreakdown(_ breakdown: [String: Double]) -> some View {
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
                // Reject all scenarios for preference learning
                if recipe.learnable {
                    for i in 0..<optimizerService.scenarios.count {
                        optimizerService.rejectScenario(at: i)
                    }
                }
                onBack()
            }) {
                Text("Try Another")
            }
            .buttonStyle(.action(role: .secondary))
            .keyboardShortcut(.cancelAction)

            Spacer()

            if recipe.display == .dryRun {
                Button(action: {
                    Haptics.tap()
                    onDone()
                }) {
                    Text("Close")
                }
                .buttonStyle(.action(role: .primary))
                .keyboardShortcut(.defaultAction)
            } else {
                let isApplied = appliedIndex == selectedScenarioIndex
                Button(action: {
                    Haptics.tap()
                    optimizerService.applyRecipeScenario(
                        at: selectedScenarioIndex,
                        to: reminderService
                    )
                    appliedIndex = selectedScenarioIndex
                }) {
                    Label(
                        isApplied ? "Applied" : "Apply Schedule",
                        systemImage: isApplied ? "checkmark.circle" : "checkmark.circle.fill"
                    )
                }
                .buttonStyle(.action(role: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(isApplied || optimizerService.scenarios.isEmpty)
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
