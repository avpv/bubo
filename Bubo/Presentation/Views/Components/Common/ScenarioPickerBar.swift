import SwiftUI
import BuboDomain
import BuboOptimizer

// MARK: - Scenario Picker Bar
//
// Main-Job fix #4 (J4): when the optimizer returns more than one
// scenario on its Pareto front, the user should be able to *see and
// compare* them — not be handed `scenarios[0]` like a verdict.
//
// The bar is a horizontal tab strip that sits above the timeline after
// a Plan run. Each tab is one scenario; the first is "Current" (real
// schedule), the rest are A / B / C ghosts. Below each tab a one-line
// trade-off label explains *why* this scenario beats the others.
//
// Tap a tab → host swaps the timeline's rendered scenario (the host
// owns the ghost-rendering pipeline; this view is pure picker).
// "Apply" commits the active scenario via `OptimizerService.applyScenario`.
//
// Birman: «pluralism on the screen» — give the user the choice the
// algorithm actually computed, instead of pre-deciding for them.

/// One pickable entry — either the current schedule or a generated
/// scenario. Hosts build the array from
/// `OptimizerService.scenarios + the current real schedule`.
struct ScenarioPick: Identifiable {
    let id: String
    /// Short tab label — `"Current"`, `"Plan A"`, `"Plan B"`, etc.
    let label: String
    /// One-line trade-off: `"deadlines first"`, `"focus protected"`,
    /// `"earliest finish (17:30)"`. Drives the active tab's caption.
    let tradeOff: String?
    /// Backing scenario when this pick represents an algorithm output.
    /// `nil` for the "Current" tab — there's no scenario to apply, the
    /// user is already on that schedule.
    let scenario: ScheduleScenario?
}

struct ScenarioPickerBar: View {
    let picks: [ScenarioPick]
    @Binding var selectedID: String
    /// Commit the currently-selected scenario. The host is responsible
    /// for routing through `OptimizerService.applyScenario` and for
    /// emitting the post-apply toast / undo. nil = "Apply" button hidden
    /// (read-only preview surfaces).
    var onApply: ((ScheduleScenario) -> Void)? = nil
    /// Dismiss the picker — the user picked Current or wants to back
    /// out. nil = dismiss button hidden.
    var onDismiss: (() -> Void)? = nil

    @Environment(\.activeSkin) private var skin

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            tabRow
            if let active = activePick {
                tradeOffRow(active)
            }
        }
        .padding(.horizontal, DS.Spacing.contentMargin)
        .padding(.vertical, DS.Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scenario picker — choose how today is planned")
    }

    // MARK: - Tab row

    private var tabRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(picks) { pick in
                    tabButton(pick)
                }
            }
        }
    }

    private func tabButton(_ pick: ScenarioPick) -> some View {
        let isActive = pick.id == selectedID
        return Button {
            Haptics.tap()
            selectedID = pick.id
        } label: {
            Text(pick.label)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular, design: skin.resolvedFontDesign))
                .foregroundStyle(isActive ? skin.resolvedTextPrimary : skin.resolvedTextSecondary)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.xs)
                .background(
                    Capsule(style: .continuous)
                        .fill(isActive ? skin.accentColor.opacity(DS.Mix.accentLight) : Color.clear)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isActive
                                ? skin.accentColor.opacity(DS.Mix.accentStrong)
                                : skin.resolvedTextPrimary.opacity(DS.Mix.surfaceDivider),
                            lineWidth: DS.Border.thin
                        )
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pick.label)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Trade-off row

    @ViewBuilder
    private func tradeOffRow(_ pick: ScenarioPick) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            if let tradeOff = pick.tradeOff {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                Text(tradeOff)
                    .font(.system(size: 12, weight: .regular, design: skin.resolvedFontDesign))
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Spacing.xs)

            if let scenario = pick.scenario, let onApply {
                Button {
                    Haptics.impact()
                    onApply(scenario)
                } label: {
                    Text("Apply")
                        .font(.system(size: 12, weight: .semibold, design: skin.resolvedFontDesign))
                        .foregroundStyle(DS.contrastingForeground(for: skin.accentColor))
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.xxs)
                        .background(
                            Capsule(style: .continuous).fill(skin.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .help("Apply this scenario to the calendar")
            } else if let onDismiss, pick.scenario == nil {
                Button {
                    Haptics.tap()
                    onDismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 12, weight: .regular, design: skin.resolvedFontDesign))
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.xxs)
                }
                .buttonStyle(.plain)
                .help("Close the picker")
            }
        }
    }

    private var activePick: ScenarioPick? {
        picks.first(where: { $0.id == selectedID })
    }
}

// MARK: - Trade-off composer
//
// Derives a one-line trade-off label from a scenario's
// `objectiveBreakdown`. Pure function so hosts and tests share one
// rule for "why does Plan A beat Plan B?" phrasing.

enum ScenarioTradeOffComposer {

    /// Build a short, human-readable rationale for a scenario by
    /// comparing its objective scores against the rest of the front.
    /// Picks the objective on which this scenario is *most distinctive*
    /// (greatest positive delta vs the median) and phrases it as a
    /// strength.
    static func tradeOff(
        for scenario: ScheduleScenario,
        peers: [ScheduleScenario]
    ) -> String? {
        guard !peers.isEmpty else { return nil }
        let breakdown = scenario.objectiveBreakdown
        guard !breakdown.isEmpty else { return nil }

        var bestObjective: (key: String, delta: Double)? = nil
        for (key, value) in breakdown {
            let peerValues = peers.compactMap { $0.objectiveBreakdown[key] }
            guard !peerValues.isEmpty else { continue }
            let median = peerValues.sorted()[peerValues.count / 2]
            let delta = value - median
            if bestObjective == nil || abs(delta) > abs(bestObjective!.delta) {
                bestObjective = (key, delta)
            }
        }
        guard let best = bestObjective else { return nil }
        return phrase(objective: best.key, delta: best.delta)
    }

    /// Human-readable strength phrasing per known objective key. Keys
    /// match `FitnessObjective` cases used in the optimizer's
    /// breakdown; unknown keys fall back to the raw key.
    private static func phrase(objective: String, delta: Double) -> String {
        let direction = delta > 0 ? "stronger" : "weaker"
        switch objective {
        case "deadlinePressure": return "deadlines first"
        case "focusTimeProtected", "focusProtection": return "focus protected"
        case "earliestFinish", "completionTime": return "earliest finish"
        case "peakHourMatch", "peakEnergy": return "matches peak hours"
        case "contextSwitches": return "fewer context switches"
        case "meetingBufferRespected": return "more meeting buffer"
        case "stability": return "minimal disruption to current plan"
        default: return "\(objective) \(direction)"
        }
    }
}
