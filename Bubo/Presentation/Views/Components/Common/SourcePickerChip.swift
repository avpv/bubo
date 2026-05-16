import SwiftUI

// MARK: - Source Picker Chip
//
// Visual primitive matching the prototype's `.source-picker` (in
// `docs/refactor/prototype-spec.md` §2):
//
//   pill shape (`--radius-pill`), padding 4 px 6 px 4 px 8 px
//   bg = `rgba(255,255,255,0.5)` on light skins, `rgba(255,255,255,0.06)`
//        on dark (we resolve via skin.resolvedTextPrimary at low alpha)
//   border 0.5 px `rgba(0,0,0,0.14)` (skin.resolvedTextPrimary 14 %)
//   font 500 11.5/1, chevron-down at the end
//
// Used in:
//   • Backlog scope row: "📥 All Tasks ▾"
//   • Inline source filters across the app whenever the user picks a
//     scope (calendar set, project, etc.).
//
// The chip is purely visual chrome. Its tap handler is the caller's:
// it composes with `.menu` or `.popover` to surface the actual picker.

struct SourcePickerChip: View {
    /// Leading glyph or emoji. SF Symbol when prefixed by a system
    /// name, or a literal character (`"📥"`). Pass nil to omit.
    var systemImage: String? = nil
    /// Optional literal leading glyph — emoji that aren't in SF
    /// Symbols (`"📥"`, `"🗂"`). Wins over `systemImage` when set.
    var leadingGlyph: String? = nil
    let title: String
    /// When `true`, renders a trailing chevron-down to signal that
    /// tapping opens a picker. Disable for read-only chips.
    var showsChevron: Bool = true

    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            if let leadingGlyph {
                Text(leadingGlyph)
                    .font(.system(size: 12))
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: skin.resolvedSymbolWeight))
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
            Text(title)
                .font(.system(size: 12, weight: .regular, design: skin.resolvedFontDesign))
                .foregroundStyle(skin.resolvedTextPrimary)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, showsChevron ? 6 : 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(skin.resolvedTextPrimary.opacity(DS.Mix.surfaceChip))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    skin.resolvedTextPrimary.opacity(DS.Mix.surfaceSeparator),
                    lineWidth: DS.Border.thin
                )
        )
        .contentShape(Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
