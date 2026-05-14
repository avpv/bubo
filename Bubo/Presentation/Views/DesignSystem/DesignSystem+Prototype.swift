import SwiftUI

// MARK: - Prototype-aligned semantic surfaces
//
// These tokens carry the visual contract from the HTML prototype
// (`docs/refactor/prototype-spec.md`) into Swift without disturbing the
// existing `DS.Spacing` / `DS.Size` / `DS.Colors` ramps that downstream
// views already bind against. New views should reach for these; legacy
// surfaces migrate at their own pace.
//
// Birman: «one rhythm, one source». We don't bolt another colour-set
// onto the side — we add an explicit semantic layer that resolves to
// existing `skin` material so light / dark / system / coffee skins all
// keep working.

extension DS {

    // MARK: Prototype foreground opacity ramp
    //
    // The prototype uses `--fg-1..4` as a four-step text/divider ramp
    // (see `docs/refactor/prototype-spec.md` — "Foreground (text) opacity
    // ramp"). Map each role to an explicit opacity over the active
    // skin's resolved primary label.

    enum Fg {
        /// 100 % — titles, primary numerals, focused active-state labels.
        /// In Swift: `skin.resolvedTextPrimary` direct, no opacity dim.
        static let primaryOpacity: Double = 1.0
        /// ≈ 70 % — meta lines, icon-button glyphs at rest, secondary
        /// labels. In Swift: `skin.resolvedTextSecondary`.
        static let secondaryOpacity: Double = 0.7
        /// ≈ 45 % — section heads, placeholders, time-offsets, declined
        /// titles, footer hints. In Swift: `skin.resolvedTextTertiary`.
        static let tertiaryOpacity: Double = 0.45
        /// ≈ 12 % — divider rules (`--fg-4`). In Swift: a hairline
        /// `.separator` at this opacity for in-content rules
        /// (e.g. the working-hours bookend's 18 px rule).
        static let dividerOpacity: Double = 0.12
    }

    // MARK: Prototype tint mix percentages
    //
    // The prototype builds every translucent surface as
    // `color-mix(in srgb, var(--fg-1) N%, transparent)` or
    // `color-mix(in srgb, var(--accent) N%, transparent)`. Naming the
    // canonical N% values here means call-sites read as intent
    // ("hover background", "subtle chip fill") instead of magic
    // numbers (`0.10`). Each maps to an existing `DS.Opacity` token
    // where one is available; otherwise we add a precise constant.

    enum Mix {
        /// `color-mix(...fg-1 4%, transparent)` — bb-shimmer rest state,
        /// `.tp-actions` background.
        static let surfaceQuiet: Double = 0.04
        /// `color-mix(...fg-1 5%, transparent)` — most surface chips at
        /// rest (city-chip, source-picker on light skin).
        static let surfaceChip: Double = 0.05
        /// `color-mix(...fg-1 6%, transparent)` — color-filter
        /// background, platform-chip bg.
        static let surfaceFilter: Double = 0.06
        /// `color-mix(...fg-1 7%, transparent)` — kbd-chip background.
        static let surfaceKbd: Double = 0.07
        /// `color-mix(...fg-1 8%, transparent)` — progress track bg,
        /// in-content dividers, scope-chip border, task-order toolbar bg.
        static let surfaceDivider: Double = 0.08
        /// `color-mix(...fg-1 10%, transparent)` — icon-button
        /// background (when shown), ring-mini track stroke.
        static let surfaceIcon: Double = 0.10
        /// `color-mix(...fg-1 12%, transparent)` — hover lift over
        /// neutral surfaces, density-bar background.
        static let surfaceHover: Double = 0.12
        /// `color-mix(...fg-1 14%, transparent)` — vertical separators
        /// (`.cf-sep`) and avatar-overlap punch-out shade.
        static let surfaceSeparator: Double = 0.14

        // MARK: Accent mixes (over --accent)

        /// `color-mix(...accent 5%, transparent)` — topbar, footer,
        /// composer at rest, event-row hover state, free-slot hover.
        static let accentBg: Double = 0.05
        /// `color-mix(...accent 8%, transparent)` — city-chip "here"
        /// state, plan-day banner background, scheduled-task tint.
        static let accentLight: Double = 0.08
        /// `color-mix(...accent 10%, transparent)` — icon-button hover,
        /// city-chip hover.
        static let accentHover: Double = 0.10
        /// `color-mix(...accent 12%, transparent)` — primary button
        /// pressed state, tp-btn hover.
        static let accentPressed: Double = 0.12
        /// `color-mix(...accent 14%, transparent)` — add-btn idle on
        /// free slots; deeper than `.accentPressed` to read as "I am
        /// a target", not a hover.
        static let accentTarget: Double = 0.14
        /// `color-mix(...accent 18%, transparent)` — cmd-row active
        /// background, hover-emphasised CTAs.
        static let accentActive: Double = 0.18
        /// `color-mix(...accent 22%, transparent)` — city-chip "here"
        /// border, source-picker stroke. Loudest semi-transparent
        /// accent before fully solid.
        static let accentStrong: Double = 0.22
        /// `color-mix(...accent 24%, transparent)` — add-btn hover.
        static let accentSolid: Double = 0.24
    }

    // MARK: Prototype shadows
    //
    // Names from the spec table (`--shadow-popover`, deeper variants
    // for command palette, alert, pomodoro). Centralised so all popover
    // shells declare depth as a level, not arithmetic.

    enum PopoverShadow {
        /// `0 14 40 rgba(0,0,0,0.40)` — default popover shadow.
        static let radius: CGFloat = 40
        static let y: CGFloat = 14
        static let opacity: Double = 0.40
        /// `0 18 50 rgba(0,0,0,0.55)` — heavier weight for the command
        /// palette, which floats clearly above all other popovers.
        static let paletteRadius: CGFloat = 50
        static let paletteY: CGFloat = 18
        static let paletteOpacity: Double = 0.55
        /// `0 30 80 rgba(0,0,0,0.55)` — heaviest, for the J4
        /// fullscreen meeting alert canvas.
        static let alertRadius: CGFloat = 80
        static let alertY: CGFloat = 30
        static let alertOpacity: Double = 0.55
    }

    // MARK: Prototype motion

    enum Motion {
        /// `--transition-micro` — 120 ms ease. Used on hover-state
        /// changes (icon-btn, city-chip, plan-day, sel-btn). Matches
        /// the `transition: opacity 120ms ease, background 120ms ease`
        /// pattern used throughout the prototype.
        static let micro: SwiftUI.Animation = .easeInOut(duration: 0.12)
    }
}
