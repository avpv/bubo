import SwiftUI

// MARK: - Keyboard Hint Chip
//
// Single source of truth for every keyboard-hint pill in the prototype:
//   • backlog composer hints ("↩ Add", "⇧↩ Details", "⎋ Cancel")
//   • settings rows (`.kbd-row .k`)
//   • command palette footer (.cmd-foot-hint .k)
//   • plan-day banner (right-side "↩")
//
// Spec (from `docs/refactor/prototype-spec.md` cross-cutting #4):
// mono 10/1, `--fg-2`, `--fg-1` 7 % bg, 0.5 px white-10 % border,
// radius 4, padding `3 5`, min-width 12, centered.
//
// Birman: «одна форма для одной роли» — every kbd pill in the app uses
// this view; no per-call reinvention.

struct KbdChip: View {
    let symbol: String

    @Environment(\.activeSkin) private var skin

    var body: some View {
        Text(symbol)
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .foregroundStyle(skin.resolvedTextSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(minWidth: 12)
            .background(
                RoundedRectangle(cornerRadius: DS.Size.microCornerRadius, style: .continuous)
                    .fill(skin.resolvedTextPrimary.opacity(DS.Mix.surfaceKbd))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.microCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(DS.Opacity.faintBorder), lineWidth: DS.Border.thin)
            )
            .accessibilityLabel("Keyboard shortcut: \(symbol)")
    }
}

/// Sequence of `KbdChip`s with a label after, e.g. "↩ Add" or
/// "⇧ ↩ Details". Use this to keep the hint-row a single object
/// instead of a stack of `Text("↩"), Text("Add")` pairs.
struct KbdHint: View {
    let keys: [String]
    let label: String

    @Environment(\.activeSkin) private var skin

    init(_ keys: [String], _ label: String) {
        self.keys = keys
        self.label = label
    }

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    KbdChip(symbol: key)
                }
            }
            Text(label)
                .font(.system(size: 11, weight: .regular, design: skin.resolvedFontDesign))
                .foregroundStyle(skin.resolvedTextTertiary)
        }
    }
}
