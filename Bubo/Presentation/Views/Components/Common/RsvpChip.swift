import SwiftUI

// MARK: - RSVP Chip
//
// Compact "needs your RSVP" / "accepted" / "declined" indicator that
// appears at the trail of an event row (`.rsvp-chip` in
// `prototype-spec.md` §1):
//
//   accepted state visuals:
//     bg = system-orange 14 %
//     border 0.5 px system-orange 30 %
//     fg = system-orange
//     padding 2 6, radius 5
//
// Each status uses its own colour family so the chip's hue carries
// the meaning at a glance: orange = "you haven't replied", green =
// "accepted", red = "declined", grey = "tentative".

enum RsvpStatus: String, CaseIterable {
    case needsAction
    case accepted
    case declined
    case tentative

    var label: String {
        switch self {
        case .needsAction: return "RSVP"
        case .accepted:    return "Going"
        case .declined:    return "Declined"
        case .tentative:   return "Tentative"
        }
    }

    /// Tint resolves against the active skin so the destructive /
    /// warning / success ramps follow the skin's overrides instead
    /// of hard-coding system colours.
    func color(skin: SkinDefinition) -> Color {
        switch self {
        case .needsAction: return skin.resolvedWarningColor
        case .accepted:    return skin.resolvedSuccessColor
        case .declined:    return skin.resolvedDestructiveColor
        case .tentative:   return skin.resolvedTextSecondary
        }
    }
}

struct RsvpChip: View {
    let status: RsvpStatus

    @Environment(\.activeSkin) private var skin

    var body: some View {
        let tint = status.color(skin: skin)
        Text(status.label)
            .font(.system(size: 11, weight: .semibold, design: skin.resolvedFontDesign))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tint.opacity(DS.Mix.surfaceSeparator))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(tint.opacity(0.30), lineWidth: DS.Border.thin)
            )
            .accessibilityLabel("RSVP \(status.label)")
    }
}
