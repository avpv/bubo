import SwiftUI

// MARK: - Popover Shell
//
// Shared wrapper for every popover surface in the prototype: the menu-bar
// Today popover, Backlog (Add / Selected / Empty), Task details, Slot
// picker, Pomodoro, Command palette, Settings. The contract:
//
//   • Material: blurred surface (`.regularMaterial`) so wallpaper bleeds
//     through the way `backdrop-filter: blur(40px) saturate(180%)` does
//     in the HTML.
//   • Radius: prototype `--radius-lg` (14 pt) for all popovers.
//   • Border: 0.5 px hairline (`rgba(0,0,0,0.10)` analogue, derived from
//     the active skin's separator opacity).
//   • Shadow: `0 14 40 rgba(0,0,0,0.40)` — see `DS.PopoverShadow`. Use
//     `.palette` for the command palette, `.alert` for the J4 canvas.
//   • Skin halo: an optional `--skin-bg` radial gradient painted at the
//     top-leading corner (`color-mix(accent 10%/2%/0%, transparent)`),
//     gated by `skin.isClassic` — classic skins skip the halo.
//
// Birman: «один объект — одна форма». Every popover binds to this shell
// instead of redoing background + corner + shadow per call site. New
// popovers should compose `PopoverShell { … }` as their root.

extension DS.PopoverShadow {
    /// Depth presets shared by every popover. The default
    /// (`.standard`) is the spec `--shadow-popover`; heavier variants
    /// belong to the command palette and the J4 alert.
    enum Depth {
        case standard
        case palette
        case alert

        var radius: CGFloat {
            switch self {
            case .standard: return DS.PopoverShadow.radius
            case .palette: return DS.PopoverShadow.paletteRadius
            case .alert: return DS.PopoverShadow.alertRadius
            }
        }
        var y: CGFloat {
            switch self {
            case .standard: return DS.PopoverShadow.y
            case .palette: return DS.PopoverShadow.paletteY
            case .alert: return DS.PopoverShadow.alertY
            }
        }
        var opacity: Double {
            switch self {
            case .standard: return DS.PopoverShadow.opacity
            case .palette: return DS.PopoverShadow.paletteOpacity
            case .alert: return DS.PopoverShadow.alertOpacity
            }
        }
    }
}

/// Top-leading accent halo. Mirrors `.skin-system .popover::before` in
/// the prototype — a quiet radial tint that gives the popover a sense
/// of where the light is coming from without claiming a full
/// background.
private struct SkinHalo: View {
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let edge = max(proxy.size.width, proxy.size.height)
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: accent.opacity(DS.Mix.accentHover), location: 0.0),
                    .init(color: accent.opacity(0.02), location: 0.40),
                    .init(color: .clear, location: 0.70)
                ]),
                center: .topLeading,
                startRadius: 0,
                endRadius: edge
            )
            .allowsHitTesting(false)
        }
    }
}

/// Shared popover container — apply once at the root of any popover-
/// shaped surface.
struct PopoverShell<Content: View>: View {
    var radius: CGFloat = DS.Size.radiusLg
    var depth: DS.PopoverShadow.Depth = .standard
    /// When `true`, paints the accent-tinted radial halo at the top-
    /// leading corner. Off for classic skins (no `--skin-bg`).
    var showsSkinHalo: Bool = true
    @ViewBuilder var content: () -> Content

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content()
            .background {
                ZStack {
                    if reduceTransparency {
                        Rectangle().fill(skin.resolvedPlatterMaterial)
                    } else {
                        Rectangle().fill(.regularMaterial)
                    }
                    if showsSkinHalo, !skin.isClassic {
                        SkinHalo(accent: skin.accentColor)
                    }
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    Color.black.opacity(DS.Opacity.faintBorder),
                    lineWidth: DS.Border.thin
                )
            }
            .shadow(
                color: Color.black.opacity(depth.opacity),
                radius: depth.radius,
                y: depth.y
            )
    }
}
