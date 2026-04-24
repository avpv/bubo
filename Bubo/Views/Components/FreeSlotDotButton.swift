import SwiftUI

/// Hollow companion to `ColorDotButton` for the color-filter bar. Tapping it
/// filters the timeline to only free slots so users can quickly eyeball where
/// they have open time. Mutually exclusive with color filters — toggling one
/// clears the other (handled by the caller).
struct FreeSlotDotButton: View {
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool
    var isDimmed: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            ZStack {
                // Hover background — matches ColorDotButton for consistency.
                Circle()
                    .fill(isHovered ? skin.resolvedHoverFill : Color.clear)
                    .frame(width: DS.Size.colorDotSize + DS.Spacing.sm, height: DS.Size.colorDotSize + DS.Spacing.sm)

                // Hollow ring — reads as "empty/free" next to the filled color dots.
                Circle()
                    .strokeBorder(
                        skin.resolvedTextSecondary,
                        lineWidth: DS.Border.medium
                    )
                    .frame(width: DS.Size.colorDotSize, height: DS.Size.colorDotSize)
                    .opacity(isDimmed ? 0.3 : 1.0)

                // HIG: Non-color indicator for active state (inner ring).
                if isActive {
                    Circle()
                        .strokeBorder(
                            skin.resolvedTextPrimary.opacity(DS.Opacity.overlayDark),
                            lineWidth: DS.Border.medium
                        )
                        .frame(
                            width: DS.Size.colorDotSize - DS.Border.medium * 2,
                            height: DS.Size.colorDotSize - DS.Border.medium * 2
                        )
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
            // Elevation shadow — matches ColorDotButton hover depth.
            .shadow(
                color: isHovered ? skin.resolvedHoverShadowColor : .clear,
                radius: isHovered ? skin.hoverShadowRadius : 0,
                y: isHovered ? skin.hoverShadowY : 0
            )
            .padding(DS.Spacing.xs)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DS.Animation.motionAware(skin.resolvedMicroAnimation, reduceMotion: reduceMotion)) {
                isHovered = hovering
            }
            if hovering { Haptics.tap() }
        }
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
        .motionAwareAnimation(skin.resolvedMicroAnimation, value: isHovered, reduceMotion: reduceMotion)
        .motionAwareAnimation(skin.resolvedMicroAnimation, value: isFocused, reduceMotion: reduceMotion)
        .motionAwareAnimation(skin.resolvedMicroAnimation, value: isActive, reduceMotion: reduceMotion)
        .help("Free slots only")
        .accessibilityLabel("Free slots only")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
