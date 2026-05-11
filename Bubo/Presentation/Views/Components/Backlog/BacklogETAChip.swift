import SwiftUI

/// «→ 17:30 (+1d)» chip in the fullscreen backlog header — when the entire
/// visible backlog will finish if started now. `TimelineView(.everyMinute)`
/// re-runs the host's `etaLabel(now:)` so the number doesn't freeze at
/// popover-open time.
///
/// The label closure is owned by the host because the calculation pulls
/// in `visibleTasks` + `totalMinutes`; passing the function keeps this
/// view free of model wiring.
struct BacklogETAChip: View {
    let etaLabel: (Date) -> String?

    @Environment(\.activeSkin) private var skin

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            if let label = etaLabel(ctx.date) {
                HStack(spacing: DS.Spacing.xxs) {
                    Text("\u{2192}")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextTertiary)
                    Text(label)
                        .font(.footnote.weight(.medium).monospacedDigit())
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .contentTransition(.numericText())
                        .accessibilityLabel("Estimated finish time \(label)")
                }
            }
        }
    }
}
