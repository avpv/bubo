import SwiftUI

// MARK: - TipRow
//
// «Bubo found something for you» row. Sparkles icon · accent-coloured
// headline (with optional sub-copy) · filled-accent action pill on
// the right. Used in:
//
// - Backlog: «1 task ready to plan · Group snippets [Plan]» when the
//   ranker has a soft suggestion; «Plan all N tasks [▶]» as the
//   fallback when there's no specific candidate.
// - Today smart-actions: same shape, different copy («Reschedule
//   conflict — Sprint planning [Run]»).
// - Empty states / nudges: «3 tasks lined up for tomorrow [View]».
//
// PRINCIPLES §1: one primary action per surface. The action pill
// IS that primary — it must read as the obvious next move, not
// compete with sibling chips.

/// One coach-hint row: sparkles + copy + primary action.
struct TipRow: View {
    let icon: String
    let headline: String
    let subcopy: String?
    let actionLabel: String
    let action: () -> Void

    /// When true, the leading icon is rendered in skin accent and the
    /// headline reads in accent too («active suggestion» state).
    /// When false, the row is in a calmer «here's an option»
    /// rendering — used for `Plan all` fallback when no specific
    /// suggestion is firing.
    let isProminent: Bool

    @Environment(\.activeSkin) private var skin

    init(
        icon: String = "sparkles",
        headline: String,
        subcopy: String? = nil,
        actionLabel: String,
        isProminent: Bool = true,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.headline = headline
        self.subcopy = subcopy
        self.actionLabel = actionLabel
        self.isProminent = isProminent
        self.action = action
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm + 2) {
            Image(systemName: icon)
                .font(.system(size: DS.Size.iconMedium, weight: .semibold))
                .foregroundStyle(iconTint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(headlineTint)
                    .lineLimit(2)
                if let subcopy, !subcopy.isEmpty {
                    Text(subcopy)
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: action) {
                HStack(spacing: 3) {
                    Text(actionLabel)
                        .font(.callout.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: DS.Size.iconSmall, weight: .semibold))
                }
                .foregroundStyle(buttonForeground)
                .padding(.horizontal, DS.Spacing.sm + 2)
                .padding(.vertical, DS.Spacing.xs + 1)
                .background(
                    Capsule(style: .continuous)
                        .fill(skin.accentColor.opacity(buttonFillOpacity))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(actionLabel)
        }
        .padding(.horizontal, DS.Spacing.contentMargin)
        .padding(.vertical, DS.Spacing.sm)
    }

    private var iconTint: Color {
        isProminent ? skin.accentColor : skin.resolvedTextSecondary
    }

    private var headlineTint: Color {
        isProminent ? skin.accentColor : skin.resolvedTextPrimary
    }

    private var buttonForeground: Color {
        isProminent ? skin.accentColor : skin.resolvedTextPrimary
    }

    private var buttonFillOpacity: Double {
        isProminent ? DS.Opacity.mediumFill : DS.Opacity.lightFill
    }
}

// MARK: - Preview

#if DEBUG
#Preview("TipRow · variants") {
    VStack(spacing: 0) {
        // Active suggestion — Backlog tip-row
        TipRow(
            headline: "1 task ready to plan · Group snippets",
            subcopy: "Bubo found a 1 h slot before standup. Schedule for 09:30?",
            actionLabel: "Plan"
        ) {}

        Divider().opacity(DS.Opacity.faintBorder)

        // No suggestion — Plan all fallback
        TipRow(
            headline: "Plan all 3 tasks",
            subcopy: nil,
            actionLabel: "Run",
            isProminent: false
        ) {}

        Divider().opacity(DS.Opacity.faintBorder)

        // Today smart-action
        TipRow(
            icon: "bolt.fill",
            headline: "Reschedule conflict — Sprint planning",
            subcopy: "Bubo found a free slot at 16:00. Move it?",
            actionLabel: "Run"
        ) {}

        Divider().opacity(DS.Opacity.faintBorder)

        // Tomorrow nudge
        TipRow(
            icon: "sunrise.fill",
            headline: "Tomorrow is shaping up too",
            subcopy: "3 tasks already slotted for Wed · 09:00–14:30",
            actionLabel: "View",
            isProminent: false
        ) {}
    }
    .frame(width: 360)
}
#endif
