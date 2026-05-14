import SwiftUI

// MARK: - When Chip
//
// Tiny scheduled-time pill used by backlog tasks to say
// "this is already on the calendar at <day> <time>". Mirrors the
// prototype's `.when-chip` (in `docs/refactor/prototype-spec.md` §2):
//
//   bg = cal-color 14 % mix
//   fg = cal-color
//   font weight-semibold 11 / 1
//   padding 2 6, radius 4
//
// One-line copy: `📅 Tue 14:00` (or `Today 09:30`, `Tomorrow 16:00`,
// etc). The caller supplies the rendered string — formatting belongs
// to the host, not the atom.

struct WhenChip: View {
    /// Pre-formatted display string. Examples: "Tue 14:00", "Today
    /// 09:30", "Wed 11–12". Includes any leading icon as a glyph
    /// when desired (the prototype uses a calendar emoji).
    let label: String
    /// Tint colour — typically the task's `--cal-color`. Falls back
    /// to the active skin's accent when nil.
    var color: Color? = nil

    @Environment(\.activeSkin) private var skin

    var body: some View {
        let tint = color ?? skin.accentColor
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: skin.resolvedFontDesign))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: DS.Size.microCornerRadius, style: .continuous)
                    .fill(tint.opacity(DS.Mix.surfaceSeparator))
            )
            .accessibilityLabel("Scheduled \(label)")
    }
}
