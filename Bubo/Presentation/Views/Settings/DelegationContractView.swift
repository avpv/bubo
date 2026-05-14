import SwiftUI
import BuboDomain

// MARK: - Delegation Contract View
//
// Main-Job fix #1: the explicit "what I do for you / what I will never
// do" surface. Without this, "доверить машине" never starts — the user
// has no contract to evaluate.
//
// Lives in Settings > Optimizer as the first card, and is also surfaced
// on first launch via the onboarding hook. Pure copy + glyphs — no
// state, no actions. The point is to make the social contract between
// user and machine explicit and findable.
//
// Birman: "the rules of the relationship live on the screen, not in
// the user's head."

struct DelegationContractView: View {

    @Environment(\.activeSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            header

            section(
                title: "I will",
                tone: .success,
                items: positiveDuties
            )

            section(
                title: "I will never",
                tone: .destructive,
                items: forbiddenDuties
            )

            footnote
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "handshake.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(skin.accentColor)
                Text("Our delegation contract")
                    .font(DS.Typography.headline(skin: skin))
                    .foregroundStyle(skin.resolvedTextPrimary)
            }
            Text("You hired Bubo to take scheduling off your plate. Here's what that means, in plain language.")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func section(title: String, tone: BannerTone, items: [String]) -> some View {
        let tint = tone.color(skin: skin)
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: tone == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextPrimary)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: DS.Spacing.sm) {
                        Circle()
                            .fill(tint.opacity(DS.Mix.accentStrong))
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                        Text(item)
                            .font(.footnote)
                            .foregroundStyle(skin.resolvedTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                    .fill(tint.opacity(DS.Mix.accentLight))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                    .strokeBorder(tint.opacity(DS.Mix.accentStrong), lineWidth: DS.Border.thin)
            )
        }
    }

    private var footnote: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextTertiary)
            Text("Every change Bubo makes is reversible. Every action is logged. You can adjust this contract any time below — for example, tighten the working hours window or turn off auto-defer.")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Contract content
    //
    // Plain-language copy lives here so the contract reads as a
    // promise, not as a feature list. Each line is one duty / one
    // boundary, no jargon.

    private let positiveDuties: [String] = [
        "Plan your day every morning before you open the popover.",
        "Find slots for new tasks in your free time, respecting deadlines and working hours.",
        "Roll forward overdue tasks overnight so you start tomorrow clean.",
        "Suggest reschedule options when something won't fit.",
        "Learn when you do your best work — peak hours, focus times, Pomodoro cadence.",
        "Show what would happen before you commit to a plan."
    ]

    private let forbiddenDuties: [String] = [
        "Cancel events you've committed to.",
        "Move events you've locked.",
        "Run optimization after working hours or on non-working days, unless you ask.",
        "Share your calendar or learned patterns with anyone.",
        "Surprise you — every change has a visible toast with undo.",
        "Make decisions you haven't given me permission to make."
    ]
}
