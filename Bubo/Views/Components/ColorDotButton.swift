import SwiftUI

/// Reusable color dot button with hover, focus, and animation support.
///
/// Used in both the main color filter bar (MenuBarView) and the event color picker (AddEventView).
/// Ensures consistent sizing, hover effects, and accessibility across all color dot interactions.
struct ColorDotButton: View {
    @Environment(\.activeSkin) private var skin
    let tag: EventColorTag
    let isActive: Bool
    var isDimmed: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            ZStack {
                // Hover background — matches EventRowView hover pattern
                Circle()
                    .fill(isHovered ? skin.resolvedHoverFill : Color.clear)
                    .frame(width: DS.Size.colorDotSize + DS.Spacing.sm, height: DS.Size.colorDotSize + DS.Spacing.sm)

                Circle()
                    .fill(tag.color)
                    .frame(width: DS.Size.colorDotSize, height: DS.Size.colorDotSize)
                    .opacity(isDimmed ? 0.3 : 1.0)

                // HIG: Non-color indicator for active state
                if isActive {
                    Circle()
                        .strokeBorder(
                            skin.resolvedTextPrimary.opacity(DS.Opacity.overlayDark),
                            lineWidth: DS.Border.medium
                        )
                        .frame(width: DS.Size.colorDotSize, height: DS.Size.colorDotSize)
                }
            }
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(isHovered ? skin.platterBorderOpacity * 1.5 : 0),
                                .white.opacity(isHovered ? skin.platterBorderOpacity * 0.1 : 0),
                                .clear,
                                .white.opacity(isHovered ? skin.platterBorderOpacity * 0.4 : 0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: DS.Border.thin
                    )
                    .frame(width: DS.Size.colorDotSize + DS.Spacing.sm, height: DS.Size.colorDotSize + DS.Spacing.sm)
            )
            .scaleEffect(isActive ? 1.15 : (isHovered ? 1.1 : 1.0))
            // Color glow
            .shadow(
                color: (isActive || isHovered) ? tag.color.opacity(skin.shadowOpacity * 6) : .clear,
                radius: (isActive || isHovered) ? skin.shadowRadius * 0.5 : 0
            )
            // Elevation shadow — matches EventRowView hover depth
            .shadow(
                color: isHovered ? skin.resolvedHoverShadowColor : .clear,
                radius: isHovered ? skin.hoverShadowRadius : 0,
                y: isHovered ? skin.hoverShadowY : 0
            )
            // HIG: Expand hit area to minimum comfortable target size
            .padding(DS.Spacing.xs)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(skin.resolvedMicroAnimation) {
                isHovered = hovering
            }
            if hovering { Haptics.tap() }
        }
        // HIG: Support keyboard navigation
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .overlay(
            Circle()
                .strokeBorder(
                    isFocused ? skin.accentColor.opacity(DS.Opacity.overlayDark) : Color.clear,
                    lineWidth: DS.Size.focusRingWidth
                )
                .shadow(color: isFocused ? skin.accentColor.opacity(0.4) : .clear, radius: 4, x: 0, y: 0)
                .padding(DS.Spacing.xs / 2)
        )
        .animation(skin.resolvedMicroAnimation, value: isHovered)
        .animation(skin.resolvedMicroAnimation, value: isFocused)
        .animation(skin.resolvedMicroAnimation, value: isActive)
        // HIG: Don't use color as the only differentiator — show name on hover
        .help(tag.rawValue)
        .accessibilityLabel(tag.rawValue)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
