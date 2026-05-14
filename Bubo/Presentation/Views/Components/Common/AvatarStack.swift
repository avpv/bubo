import SwiftUI

// MARK: - Avatar Stack
//
// Overlapping participant row used on event rows that have attendees
// (`docs/refactor/prototype-spec.md` §1 — `.avatars`):
//
//   bg = fg-1 22 %
//   border 1.5 px `--surface-window`
//   16 × 16 round, -5 px overlap, `.more` is transparent fill
//
// Renders up to `visibleLimit` avatars, then a "+N more" disc that
// shares the geometry. Callers supply initials (and an optional tint)
// per attendee; we never load images here — the row trail in the menu
// bar is too small for photos and avatars carry initials in every
// product surface we've shipped.

struct Avatar: Hashable {
    let initials: String
    /// Optional tint override. Falls back to `fg-1` 22 % over the
    /// active skin's resolved primary label.
    var tint: Color? = nil

    init(initials: String, tint: Color? = nil) {
        self.initials = String(initials.prefix(2)).uppercased()
        self.tint = tint
    }

    /// Cheap initials-from-name extraction. "John Doe" → "JD",
    /// "Anastasia" → "AN". Empty input yields "?" so the disc still
    /// renders something instead of collapsing.
    static func fromName(_ name: String, tint: Color? = nil) -> Avatar {
        let words = name
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
        let chars = words.compactMap { $0.first }
        let initials = chars.isEmpty ? "?" : String(chars).uppercased()
        return Avatar(initials: initials, tint: tint)
    }
}

struct AvatarStack: View {
    let avatars: [Avatar]
    var visibleLimit: Int = 3
    var diameter: CGFloat = 16

    @Environment(\.activeSkin) private var skin

    /// Negative spacing produces the prototype's `-5 px` overlap. We
    /// derive it from `diameter` so the overlap stays proportional if
    /// a caller bumps the size for a larger surface (settings preview).
    private var overlap: CGFloat { -diameter * 0.3125 }

    var body: some View {
        let visible = Array(avatars.prefix(visibleLimit))
        let remaining = avatars.count - visible.count
        HStack(spacing: overlap) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, avatar in
                avatarDisc(avatar: avatar, isMore: false)
            }
            if remaining > 0 {
                moreDisc(remaining: remaining)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func avatarDisc(avatar: Avatar, isMore: Bool) -> some View {
        let tint = avatar.tint ?? skin.resolvedTextPrimary.opacity(DS.Mix.accentStrong)
        return ZStack {
            Circle().fill(tint)
            Text(avatar.initials)
                .font(.system(size: diameter * 0.5, weight: .semibold, design: skin.resolvedFontDesign))
                .foregroundStyle(DS.contrastingForeground(for: tint))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(width: diameter, height: diameter)
        .overlay(
            Circle().strokeBorder(
                skin.resolvedPlatterMaterial.opacity(1.0),
                lineWidth: DS.Border.medium
            )
        )
    }

    private func moreDisc(remaining: Int) -> some View {
        ZStack {
            Circle().fill(Color.clear)
            Text("+\(remaining)")
                .font(.system(size: diameter * 0.4, weight: .semibold, design: skin.resolvedFontDesign))
                .foregroundStyle(skin.resolvedTextSecondary)
                .minimumScaleFactor(0.6)
        }
        .frame(width: diameter, height: diameter)
        .overlay(
            Circle().strokeBorder(
                skin.resolvedTextPrimary.opacity(DS.Mix.surfaceSeparator),
                lineWidth: DS.Border.thin
            )
        )
    }

    private var accessibilityLabel: String {
        if avatars.isEmpty { return "No participants" }
        if avatars.count == 1 { return "1 participant" }
        return "\(avatars.count) participants"
    }
}
