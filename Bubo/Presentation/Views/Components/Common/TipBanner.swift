import SwiftUI

// MARK: - Tip Banner
//
// Shared call-out used for the prototype's `.tip-row`, `.plan-day` and
// `.tomorrow-banner` shapes (`docs/refactor/prototype-spec.md` §2):
//
//   • icon on the leading edge (bulb / sunrise / sparkles), tinted by
//     `accent` / `system-green` / role
//   • two-line copy block — head (semibold, primary tint) + sub
//     (regular, fg-3)
//   • optional trailing action — accent kbd hint OR a button like
//     "Plan" / "→ View"
//
// Styling:
//   margin 0 12 8 / padding 8 12 / radius `--radius-md` (10 pt)
//   bg = tint 8 % / border 0.5 px tint 22 % / no shadow.
//
// `BannerTone` swaps the tint family without changing geometry, so the
// banner reads as one shape across "Plan ready" (accent), "Tomorrow
// peek" (system-green), and any future surfaces that want to surface
// a one-line suggestion with an action.

enum BannerTone {
    case accent
    case success
    case warning
    case destructive
    case quiet

    func color(skin: SkinDefinition) -> Color {
        switch self {
        case .accent:      return skin.accentColor
        case .success:     return skin.resolvedSuccessColor
        case .warning:     return skin.resolvedWarningColor
        case .destructive: return skin.resolvedDestructiveColor
        case .quiet:       return skin.resolvedTextSecondary
        }
    }
}

struct TipBanner<Trailing: View>: View {
    /// SF Symbol on the leading edge. Default `lightbulb.fill` matches
    /// the prototype's `.tip-row` sparkles glyph; specific banners can
    /// supply their own (`sunrise` for tomorrow-peek, `checkmark.circle`
    /// for "all fits inside today", etc.).
    var systemImage: String = "lightbulb.fill"
    let head: String
    /// Optional second-line copy. Nil = single-line banner (the
    /// `.plan-day` variant in the prototype).
    var sub: String? = nil
    var tone: BannerTone = .accent
    /// Trailing accessory — typically a `Button("Plan")`,
    /// `KbdChip("↩")`, or an arrow link.
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.activeSkin) private var skin

    init(
        systemImage: String = "lightbulb.fill",
        head: String,
        sub: String? = nil,
        tone: BannerTone = .accent,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.systemImage = systemImage
        self.head = head
        self.sub = sub
        self.tone = tone
        self.trailing = trailing
    }

    var body: some View {
        let tint = tone.color(skin: skin)
        HStack(alignment: .center, spacing: DS.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold, design: skin.resolvedFontDesign))
                .foregroundStyle(tint)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(head)
                    .font(.system(size: 12, weight: .semibold, design: skin.resolvedFontDesign))
                    .foregroundStyle(tint)
                    .lineLimit(2)
                if let sub {
                    Text(sub)
                        .font(.system(size: 12, weight: .regular, design: skin.resolvedFontDesign))
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                .fill(tint.opacity(DS.Mix.accentLight))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                .strokeBorder(tint.opacity(DS.Mix.accentStrong), lineWidth: DS.Border.thin)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sub.map { "\(head). \($0)" } ?? head)
    }
}

extension TipBanner where Trailing == EmptyView {
    init(
        systemImage: String = "lightbulb.fill",
        head: String,
        sub: String? = nil,
        tone: BannerTone = .accent
    ) {
        self.init(systemImage: systemImage, head: head, sub: sub, tone: tone) {
            EmptyView()
        }
    }
}
