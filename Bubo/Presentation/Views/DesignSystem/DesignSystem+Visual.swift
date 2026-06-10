import SwiftUI

extension DS {
    // MARK: Shadows

    enum Shadows {
        // Alert/fullscreen.
        static let glowRadius: CGFloat = 18
        static let buttonRadius: CGFloat = 10

        // Toast — sits one elevation step above the card plane. Depth comes
        // from a modest offset (`y`) and a wider blur, never a louder
        // colour, so a floating notification reads as lifted without
        // announcing itself like a modal.
        static let toastRadius: CGFloat = 24
        static let toastY: CGFloat = 10
    }

    // MARK: Elevation
    //
    // Three z-levels treated as state, not decoration. Birman: «depth is
    // a hierarchy, not a decoration». A view declares which plane it lives
    // on; the modifier picks the matching shadow recipe. One designer-
    // facing knob (the level), one shadow stack, no per-call-site drift.
    //
    //   z0 — base surface: popover body, list rows. No drop shadow — the
    //                      popover frame already lifts the whole surface.
    //   z1 — cards / banners / pills floating above the body. Skin-driven
    //        radius and Y so each skin can dial its own «paper weight».
    //   z2 — modals / overlays / floating notifications. Deeper, bolder,
    //        and skin-independent in the radius — these are user-attention
    //        surfaces where the depth must read regardless of the active
    //        skin's mood.

    enum Elevation: CaseIterable {
        case z0, z1, z2

        /// Drop-shadow blur radius for this plane.
        func radius(skin: SkinDefinition) -> CGFloat {
            switch self {
            case .z0: return 0
            case .z1: return skin.shadowRadius
            case .z2: return Shadows.toastRadius
            }
        }

        /// Vertical offset — depth-cue light comes from above.
        func y(skin: SkinDefinition) -> CGFloat {
            switch self {
            case .z0: return 0
            case .z1: return skin.shadowY
            case .z2: return Shadows.toastY
            }
        }

        /// Cast shadow colour for the level. Z1 and Z2 share the skin's
        /// shadow tint — depth difference is carried by `radius` and `y`,
        /// not by hue. Z0 is `.clear` so the modifier is a no-op for base
        /// surfaces (keeps call sites clean: every surface declares its
        /// level even when it casts nothing).
        func color(skin: SkinDefinition) -> Color {
            self == .z0 ? .clear : skin.resolvedShadowColor
        }
    }

    // MARK: Physics
    //
    // Single source of truth for the «physical feedback» constants used
    // across drag-pickup, drop-receive and press interactions in
    // `BacklogTaskRow`, `FreeSlotRow` and `IconPressStyle`. Centralised
    // so a designer dialing «all physical effects 30% softer» edits one
    // file, not five.

    enum Physics {
        /// Drag-preview thumb — slight scale-up that reads as «lifted off
        /// the page» in the floating thumb that follows the cursor. The
        /// source row stays at 1.0 and only dims (`Opacity.tertiaryText`)
        /// so we don't claim two contradictory states for one object.
        static let dragPreviewScale: CGFloat = 1.04
        static let dragPreviewShadowRadius: CGFloat = 14
        static let dragPreviewShadowY: CGFloat = 6

        /// Free-slot drop-target — soft shadow only, no scale. Border +
        /// fill already convey «I'm receiving you»; adding a third
        /// channel (scale) on top of those two pushed the slot into
        /// over-stated territory and overlapped neighbouring rows
        /// because `.scaleEffect` doesn't reflow layout.
        static let dropTargetShadowRadius: CGFloat = 8
        static let dropTargetShadowY: CGFloat = 3

        /// Press-feedback scale for naked-glyph buttons (`IconPressStyle`).
        /// Apple's system-wide press signature is `scale(0.95)` — the
        /// "barely visible squish" Apple uses on every pill, tile and
        /// chip on apple.com and across iOS. Sits between the earlier
        /// 0.92 (slightly twitchy) and 1.0 (no feedback).
        static let pressedIconScale: CGFloat = 0.95
    }

    // MARK: Animation

    enum Animation {
        static let quick: SwiftUI.Animation = .easeInOut(duration: 0.15)
        static let standard: SwiftUI.Animation = .easeInOut(duration: 0.2)
        static let entrance: SwiftUI.Animation = .easeOut(duration: 0.3)

        // Spring-based animations for natural, modern feel (macOS 2026 standard)
        static let microInteraction: SwiftUI.Animation = .spring(duration: 0.25, bounce: 0.2)
        static let gentleBounce: SwiftUI.Animation = .spring(duration: 0.35, bounce: 0.25)
        static let smoothSpring: SwiftUI.Animation = .spring(duration: 0.4, bounce: 0.2)
        static let staggerBase: SwiftUI.Animation = .spring(duration: 0.45, bounce: 0.25)

        /// Staggered entrance animation for list items.
        static func staggered(index: Int) -> SwiftUI.Animation {
            staggerBase.delay(Double(index) * 0.04)
        }

        /// «The machine is thinking» — slow ease-out, no bounce. Used by `SmartActions`
        /// when the shadow optimizer's result swaps in (state transitions
        /// between hard / soft / calm) and by the upcoming ghost-preview
        /// re-layout. Calmer than `smoothSpring` — bounce would read as
        /// playful when the goal is «the system is reasoning, give it a
        /// beat».
        static let machineWork: SwiftUI.Animation = .easeOut(duration: 0.45)

        /// Cross-fade transitions — 0.4 s ease. Used by capacity-ring
        /// progress swaps, alert pill cross-fades, and any «one state
        /// fades into another» moment. Slightly slower than `entrance`
        /// (0.3) because both ends of a transition are visible
        /// simultaneously and the eye needs time to hand off.
        static let transition: SwiftUI.Animation = .easeOut(duration: 0.4)
        static let transitionInOut: SwiftUI.Animation = .easeInOut(duration: 0.4)

        /// Disintegration / dissolve — particles fade out (`.easeOut`)
        /// and the cleanup fade-in settles (`.easeInOut`). Two phases of
        /// the same effect, named so the call-site reads as intent.
        static let dissolve: SwiftUI.Animation = .easeOut(duration: 0.3)
        static let dissolveSettle: SwiftUI.Animation = .easeInOut(duration: 0.35)

        /// Countdown progress tick — strict `.linear` so the second-by-
        /// second redraw doesn't ease in/out and feel «laggy» at the
        /// boundary of each tick.
        static let countdownTick: SwiftUI.Animation = .linear(duration: 0.3)

        /// Slow breathing pulse — repeated `.easeInOut` used for
        /// loading shimmers, ghost-preview breaths, and the timer
        /// screen's hero pulse. Three speeds: `pulseQuick` for short
        /// «freshly created» highlights, `pulse` for ambient ghosts,
        /// `pulseSlow` for hero / standby states.
        static func pulseQuick() -> SwiftUI.Animation {
            .easeInOut(duration: 0.6)
        }
        static func pulse() -> SwiftUI.Animation {
            .easeInOut(duration: 1.1)
        }
        static func pulseMedium() -> SwiftUI.Animation {
            .easeInOut(duration: 0.9)
        }
        static func pulseSlow() -> SwiftUI.Animation {
            .easeInOut(duration: 2)
        }

        /// Returns `.identity` (no animation) when Reduce Motion is on,
        /// otherwise returns the provided animation.
        static func motionAware(
            _ animation: SwiftUI.Animation,
            reduceMotion: Bool
        ) -> SwiftUI.Animation {
            reduceMotion ? .easeOut(duration: 0.01) : animation
        }
    }
}
