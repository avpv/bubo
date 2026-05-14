import SwiftUI

// MARK: - Icon Button (prototype `.icon-btn`)
//
// 28 × 28 square, `--radius-sm` (6 pt), naked rest state, hover lifts to
// `accent 10 % bg + --fg-1 glyph`. Used everywhere in the prototype:
// topbar day-nav chevrons, search, more, settings tabs, sel-bar
// dismiss, task-pop back chip.
//
// Birman: «one form, one role». Every chromeless square trigger in a
// popover wears this view; do NOT reinvent it with bare `Button` +
// `.padding()` somewhere else.

struct IconButton: View {
    /// SF Symbol name for the glyph.
    let systemName: String
    /// Optional VoiceOver label. Defaults to the symbol name; supply
    /// a human-readable string for non-obvious icons.
    var accessibilityLabel: String? = nil
    /// Optional fixed tint override. When `nil`, follows the
    /// rest/hover ramp described above.
    var tint: Color? = nil
    /// Optional explicit size. Defaults to `DS.Size.iconButton` (28 pt).
    var size: CGFloat = DS.Size.iconButton
    /// Glyph point size. Defaults to `DS.Size.iconMedium` (14 pt) —
    /// matches the prototype's 14 px icons inside 28 px buttons.
    var glyphSize: CGFloat = DS.Size.iconMedium
    let action: () -> Void

    @Environment(\.activeSkin) private var skin
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            Haptics.tap()
            action()
        }) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: skin.resolvedSymbolWeight))
                .frame(width: size, height: size)
                .foregroundStyle(foreground)
                .background(
                    RoundedRectangle(cornerRadius: DS.Size.radiusSm, style: .continuous)
                        .fill(isHovered ? skin.accentColor.opacity(DS.Mix.accentHover) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.Size.radiusSm, style: .continuous))
        }
        .buttonStyle(.iconPress)
        .onHover { hovering in
            withAnimation(DS.Motion.micro) { isHovered = hovering }
        }
        .accessibilityLabel(accessibilityLabel ?? systemName)
    }

    private var foreground: Color {
        if let tint { return tint }
        return isHovered ? skin.resolvedTextPrimary : skin.resolvedTextSecondary
    }
}
