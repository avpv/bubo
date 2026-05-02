import SwiftUI

/// Horizontal row of one-tap optimizer presets that lives on the main
/// screen above the timeline. Backed by `QuickActionRanker` so the
/// surfaced set adapts to schedule state (urgent deadlines, overdue
/// tasks, no focus block today, meeting-heavy day, morning vs evening
/// hour) and the user's history — frequently-accepted actions rise,
/// context-irrelevant ones sink.
///
/// Birman: «прямое действие на месте проблемы». The user reads the
/// timeline and the row already shows the verbs the GA can offer
/// *right now*: Find focus when there's no focus block, Plan tomorrow
/// when it's late afternoon, Fix overdue when the backlog has
/// overdue rows. No need to dive into the inline backlog or the
/// command palette to ask the optimizer for help.
///
/// Each chip taps `runQuickAction` through the host's pipe (toast +
/// undo come for free) and exposes the ranker's `reason` as a
/// tooltip — Бирман: машина видимая, не магическая.
struct QuickActionsRow: View {

    let backlogService: BacklogService
    let reminderService: ReminderService
    let intentLearner: IntentLearner
    /// Run an arbitrary `OptimizationRequest` through the host's quick-
    /// action pipe (toast + undo). Same closure shape `BacklogView`
    /// uses for its `onRunRequest`.
    let onRunRequest: (OptimizationRequest, String) async -> Void
    /// How many top-ranked actions to surface. Default 5 fits the
    /// 360pt main popover comfortably without horizontal scrolling
    /// in most cases; the row stays scrollable for narrower hosts.
    var limit: Int = 5

    @Environment(\.activeSkin) private var skin

    /// Re-rank on every render — the ranker is cheap (single pass over
    /// allEvents to gather context inputs, then a sort over ~7
    /// candidates). Doing this in the body means the row updates the
    /// instant a task is added / completed / a meeting moves, with
    /// no manual invalidation.
    private var scored: [QuickActionRanker.ScoredAction] {
        let ranker = QuickActionRanker(
            backlogService: backlogService,
            reminderService: reminderService,
            intentLearner: intentLearner
        )
        return ranker.rank(limit: limit)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(scored, id: \.id) { entry in
                    chip(for: entry)
                }
            }
            .padding(.horizontal, DS.Spacing.contentMargin)
            .padding(.vertical, DS.Spacing.xs)
        }
    }

    @ViewBuilder
    private func chip(for entry: QuickActionRanker.ScoredAction) -> some View {
        Button {
            Haptics.tap()
            Task {
                await onRunRequest(entry.action.request, entry.action.label)
            }
        } label: {
            HStack(spacing: DS.Spacing.xxs) {
                Image(systemName: entry.action.icon)
                    .font(.footnote)
                Text(entry.action.label)
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(skin.accentColor)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                Capsule().fill(skin.accentColor.opacity(DS.Opacity.lightFill))
            )
            .overlay(
                Capsule().strokeBorder(
                    skin.accentColor.opacity(DS.Opacity.softAccent),
                    lineWidth: DS.Border.thin
                )
            )
        }
        .buttonStyle(.plain)
        .help(helpText(for: entry))
        .accessibilityLabel(accessibilityLabel(for: entry))
    }

    /// Tooltip text. The ranker's `reason` explains why this chip is
    /// surfaced («3 overdue tasks», «Morning planning window»);
    /// `.alwaysAvailable` chips return an empty reason — fall back to
    /// the action label so the tooltip is never blank.
    private func helpText(for entry: QuickActionRanker.ScoredAction) -> String {
        let reason = entry.reason
        if reason.isEmpty {
            return "Run «\(entry.action.label)» — optimizer finds the best slot"
        }
        return "\(entry.action.label) · \(reason)"
    }

    private func accessibilityLabel(for entry: QuickActionRanker.ScoredAction) -> String {
        let reason = entry.reason
        if reason.isEmpty {
            return "\(entry.action.label) — runs the optimizer"
        }
        return "\(entry.action.label). \(reason)."
    }
}
