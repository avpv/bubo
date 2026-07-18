import SwiftUI

// MARK: - Shared snippet-row chrome
//
// One visual language for the two row families — backlog task rows and
// timeline event rows. Both read the leading state stripe, the hover
// fill and the keyboard-focus ring from here instead of hand-rolling
// their own variants, so «task» and «event» render as two members of
// one species: same stripe width, same hover surface, same focus ring.

/// Leading state stripe — the coloured bar that spans the row's height
/// and carries exactly one state signal (scheduled / urgent / colour
/// tag). Width and radius are shared tokens; callers own opacity,
/// vertical padding and accessibility.
struct RowStateStripe: View {
    let color: Color
    var opacity: Double = 1

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Size.stripeCornerRadius, style: .continuous)
            .fill(color.opacity(opacity))
            .frame(width: DS.Size.eventStripeWidth)
            .frame(maxHeight: .infinity)
    }
}

/// Hover fill + keyboard-focus ring + drop-target highlight, applied
/// identically to every snippet row. The drop-target fill wins over
/// hover; the focus ring rides on top and shares the corner radius so
/// the two never bleed into each other.
private struct SnippetRowChrome: ViewModifier {
    @Environment(\.activeSkin) private var skin

    let isHovered: Bool
    let isFocused: Bool
    let isDropTargeted: Bool

    private var fill: Color {
        if isDropTargeted { return skin.accentColor.opacity(DS.Opacity.mediumFill) }
        if isHovered { return skin.resolvedHoverFill }
        return .clear
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                        .strokeBorder(skin.accentColor, lineWidth: DS.Border.selection)
                }
            }
    }
}

extension View {
    /// Shared row chrome for backlog task rows and timeline event rows.
    func snippetRowChrome(
        isHovered: Bool,
        isFocused: Bool,
        isDropTargeted: Bool = false
    ) -> some View {
        modifier(SnippetRowChrome(
            isHovered: isHovered,
            isFocused: isFocused,
            isDropTargeted: isDropTargeted
        ))
    }
}
