import SwiftUI

/// Tri-state filter that controls whether free slots / events are shown in the
/// timeline. Lives next to `FreeSlotDotButton` because the button is the only
/// surface that exposes it; rendering and cycling logic stay in one place.
enum FreeSlotFilter: CaseIterable {
    /// Default — events and free slots both visible.
    case all
    /// Hide events, show only free slots so the user can eyeball open time.
    case onlyFree
    /// Show events, hide the "Free · Xh" rows so a busy day reads cleanly.
    case hideFree

    var isActive: Bool { self != .all }

    /// Cycle order: all → onlyFree → hideFree → all.
    func next() -> FreeSlotFilter {
        switch self {
        case .all: return .onlyFree
        case .onlyFree: return .hideFree
        case .hideFree: return .all
        }
    }
}

/// Hollow companion to `ColorDotButton` for the color-filter bar. Cycles
/// through three states on tap — show all, free slots only, free slots hidden
/// — so the same control covers both directions of the free-slot filter.
/// Mutually exclusive with color filters: caller clears one when the other
/// activates.
struct FreeSlotDotButton: View {
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: FreeSlotFilter
    var isDimmed: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var isActive: Bool { state.isActive }

    /// Tooltip describes the next click action so the cycle is discoverable.
    private var helpText: String {
        switch state {
        case .all: return "Show free slots only"
        case .onlyFree: return "Hide free slots"
        case .hideFree: return "Clear filter"
        }
    }

    /// VoiceOver label describes the *current* state, not the next action.
    private var accessibilityText: String {
        switch state {
        case .all: return "Free slots filter, off"
        case .onlyFree: return "Free slots only"
        case .hideFree: return "Free slots hidden"
        }
    }

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

                // Active-state indicators — non-color so the meaning survives
                // colorblind / monochrome modes.
                switch state {
                case .all:
                    EmptyView()
                case .onlyFree:
                    // Inner ring → "this is the only thing showing".
                    Circle()
                        .strokeBorder(
                            skin.resolvedTextPrimary.opacity(DS.Opacity.overlayDark),
                            lineWidth: DS.Border.medium
                        )
                        .frame(
                            width: DS.Size.colorDotSize - DS.Border.medium * 2,
                            height: DS.Size.colorDotSize - DS.Border.medium * 2
                        )
                case .hideFree:
                    // Diagonal slash → universal "no/hidden" affordance.
                    // Slightly longer than the diameter so it visually crosses
                    // the ring instead of stopping flush with it.
                    Capsule()
                        .fill(skin.resolvedTextPrimary.opacity(DS.Opacity.overlayDark))
                        .frame(width: DS.Size.colorDotSize + DS.Border.medium * 2, height: DS.Border.medium)
                        .rotationEffect(.degrees(-45))
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
        .help(helpText)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
