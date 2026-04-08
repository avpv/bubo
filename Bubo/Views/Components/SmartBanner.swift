import SwiftUI

// MARK: - Smart Banner
//
// A thin, single-line notice rendered above the event list when the RecipeMonitor
// surfaces a contextually relevant recipe (e.g. "no focus blocks today → find focus").
// Tapping the banner opens the CommandPalette seeded with that recipe.
// Dismissing it silences the banner for the rest of the session.
//
// Only one banner is ever visible at a time — we show the first suggested recipe.
// This is the "passive nudge" surface of the optimizer UI — no UI noise unless
// there's a concrete reason.

struct SmartBanner: View {
    @Environment(\.activeSkin) private var skin

    let recipe: ScheduleRecipe
    let reason: String
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "lightbulb.max.fill")
                .font(.caption)
                .foregroundStyle(skin.accentColor)
                .accessibilityHidden(true)

            Text(reason)
                .font(.caption)
                .foregroundStyle(skin.resolvedTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: DS.Spacing.xs)

            Button {
                Haptics.tap()
                onTap()
            } label: {
                HStack(spacing: 2) {
                    Text(recipe.name)
                        .font(.caption.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(skin.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Run \(recipe.name)")

            Button {
                Haptics.tap()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss suggestion")
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .fill(skin.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(skin.accentColor.opacity(0.15), lineWidth: DS.Border.thin)
        )
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.xs)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Suggestion Reason
//
// Human-readable reason for a banner, derived from the conditions that triggered
// it. Used as the banner's left-side copy.

enum SmartBannerReason {
    static func text(for recipe: ScheduleRecipe) -> String {
        if recipe.conditions.contains(where: {
            if case .noFocusBlocks = $0 { return true } else { return false }
        }) {
            return "No focus time today"
        }
        if recipe.conditions.contains(where: {
            if case .hasDeadlineWithin = $0 { return true } else { return false }
        }) {
            return "Deadline coming up"
        }
        if recipe.conditions.contains(where: {
            if case .meetingHeavy = $0 { return true } else { return false }
        }) {
            return "Heavy meeting day"
        }
        if recipe.conditions.contains(where: {
            if case .hasGapLongerThan = $0 { return true } else { return false }
        }) {
            return "Free time available"
        }
        if recipe.conditions.contains(where: {
            if case .dayOfWeek = $0 { return true } else { return false }
        }) {
            return "Start-of-week planning"
        }
        return "Suggestion"
    }
}
