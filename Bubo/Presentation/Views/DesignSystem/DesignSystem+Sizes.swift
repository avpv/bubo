import SwiftUI

extension DS {
    // MARK: Component Sizes

    enum Size {
        static let accentBarWidth: CGFloat = 4
        static let accentBarHeight: CGFloat = 28
        static let eventRowMinHeight: CGFloat = 36
        static let backlogRowHeight: CGFloat = 44
        static let headerHeight: CGFloat = 48
        static let actionFooterHeight: CGFloat = 48
        // Prototype CSS sets the time column at 78px to leave breathing
        // room for the 3pt accent stripe + 12pt gap inside the popover's
        // 360pt width without crowding the title. 84 → 78 buys back 6pt
        // for the title column without breaking tabular-num alignment.
        static let timeColumnWidth: CGFloat = 78
        static let datePillWidth: CGFloat = 54
        static let timePillWidth: CGFloat = 52
        static let controlHeight: CGFloat = 28
        static let focusRingWidth: CGFloat = 2
        static let iconSmall: CGFloat = 12
        static let iconMedium: CGFloat = 14
        static let iconLarge: CGFloat = 16
        static let headerIcon: CGFloat = 20
        /// Card / platter radius. Apple's design system anchors cards at
        /// 18pt (store utility cards) — Bubo's previous 16pt was off the
        /// reference grid. Used by every platter background and the
        /// elevated `SkinPlatterDepthModifier`.
        static let cornerRadius: CGFloat = 18
        /// Inline highlight / subtle-fill surface radius used for hints,
        /// drop targets, inline edit forms and search rows that live
        /// *inside* a larger `cornerRadius`-shaped card. Aligned to
        /// Apple's pearl-button / utility-card radius (11pt).
        static let subtleCornerRadius: CGFloat = 11
        /// Micro-radius for sub-caption2 affordances (kbd-hint badges,
        /// scheduled-when chips, project micro-tags). Apple's small
        /// utility radius (8pt).
        static let microCornerRadius: CGFloat = 8
        static let badgeCornerRadius: CGFloat = 20

        // MARK: Prototype-aligned semantic radii
        //
        // Apple's design system anchors four canonical radii:
        // 5 (inline chip) / 8 (small utility) / 11 (pearl button) / 18 (card) / 9999 (pill).
        // The semantic aliases below give every call site one place to read
        // from, and the values now map onto Apple's grid rather than the
        // earlier ad-hoc 6/10/14 sequence.

        /// Smallest rounded affordance: icon-button corners, kbd-hint
        /// chips, small badges. Apple's inline chip (5pt).
        static let radiusSm: CGFloat = 5
        /// Inline cards (plan-day banner, tip-row, status callouts).
        /// Apple's pearl-button radius (11pt).
        static let radiusMd: CGFloat = 11
        /// Top-level popover shell radius (popover, slot-picker, command
        /// palette, settings popover). 14pt holds the macOS popover
        /// convention — Apple cards bump to 18pt only for content
        /// surfaces *inside* the shell.
        static let radiusLg: CGFloat = 14
        /// True pill — chips, tags, the composer footer. Equivalent to
        /// `--radius-pill` (999). Use `.infinity` so Capsule-shaped views
        /// remain correct at any height.
        static let radiusPill: CGFloat = .infinity
        static let syncIndicatorSize: CGFloat = 14
        static let todayDotSize: CGFloat = 6

        // Timer
        static let timerRingDiameter: CGFloat = 180
        static let timerRingStrokeWidth: CGFloat = 4
        static let timerCheckmarkSize: CGFloat = 36

        // Alert
        static let alertIconSize: CGFloat = 60

        // Preview cards (settings UI) — miniature reflection of the
        // 5/8/11/18 Apple-aligned card scale.
        static let previewCardRadius: CGFloat = 5
        static let previewCardHeight: CGFloat = 40
        static let previewSmallRadius: CGFloat = 2
        static let previewMicroRadius: CGFloat = 1

        // Emoji picker
        static let emojiCellSize: CGFloat = 32
        static let emojiPickerWidth: CGFloat = 280
        static let emojiPickerHeight: CGFloat = 320

        // Inputs
        static let numberInputWidth: CGFloat = 80

        // Color tag
        static let colorDotSize: CGFloat = 14
        static let recipeDotSize: CGFloat = 8

        /// Canonical chip / pill height. Every horizontal chip — ranked
        /// SmartAction, More, capacity badge, Backlog entry, time-slot
        /// picker, hour picker, working-day picker — sits on this height
        /// so a row of chips reads as one bar, not as a ransom note of
        /// pills with different rhythm. Birman: «one ритм по высоте».
        static let chipHeight: CGFloat = 24
        static let chipHeightCompact: CGFloat = 20
        /// City-row chips (`.city-chip`) and color-filter pill
        /// (`.color-filter`) in the prototype sit at 26–28 px — slightly
        /// taller than the canonical chip so the mono time / dot rail has
        /// breathing room. 26 px matches the prototype `.city-chip`.
        static let cityChipHeight: CGFloat = 26
        /// Color-filter pill height — 28 px in the prototype, gives the
        /// inline icon + label + active dots + count + toggle enough
        /// vertical air to read as one bar.
        static let colorFilterHeight: CGFloat = 28
        /// Square icon-button. 28 px matches the prototype `.icon-btn`,
        /// the topbar day-nav chevrons, and the more / search affordances.
        static let iconButton: CGFloat = 28

        // MARK: Prototype menu-bar accents

        /// Width of the coloured stripe down the left edge of an event row.
        /// 3 px in the prototype (`.bb-event .stripe`); the existing
        /// `accentBarWidth = 4` is kept for the legacy AddEvent platter.
        static let eventStripeWidth: CGFloat = 3

        // Progress bar
        static let progressBarHeight: CGFloat = 6

        // World clock
        static let worldClockMoonSize: CGFloat = 7
    }

    // MARK: Borders

    enum Border {
        static let thin: CGFloat = 0.5
        static let standard: CGFloat = 1
        static let medium: CGFloat = 1.5
        static let selection: CGFloat = 2
    }

    // MARK: Opacity

    enum Opacity {
        // Backgrounds & fills
        static let subtleFill: Double = 0.04
        static let lightFill: Double = 0.08
        static let mediumFill: Double = 0.12
        static let strongFill: Double = 0.2

        // Text & overlays
        static let tertiaryText: Double = 0.4
        static let overlayLight: Double = 0.6
        static let overlayDark: Double = 0.8

        // Prominent fills
        static let half: Double = 0.5
        static let accentMuted: Double = 0.7

        // Borders & strokes
        static let faintBorder: Double = 0.1
        static let subtleBorder: Double = 0.15
        /// Idle stroke for input fields that need to read as fields on
        /// every wallpaper. Slightly louder than `subtleBorder` so dark
        /// or busy backgrounds don't swallow the affordance, still quiet
        /// enough to read as «input», not «button». Used by the
        /// `+ Add task…` field's idle border in both backlog modes.
        /// Birman: «a field should look like a field».
        static let borderIdle: Double = 0.18
        static let glassBorder: Double = 0.2

        /// Soft accent — louder than `subtleBorder`, quieter than `half`.
        /// Used for drag-awaiting states and hover-dimmed accents where
        /// we want presence without full saturation.
        static let softAccent: Double = 0.35

        /// Whisper fill — barely visible accent tint for dimmed/disabled
        /// chips and hover-out states. Quieter than `subtleFill` because
        /// the accent hue carries louder than neutral text at the same
        /// alpha. Was 0.05 hardcoded.
        static let whisperFill: Double = 0.05

        /// Selected-chip accent fill — the «pressed in» background for
        /// pickers (working days, energy hours, color tags). Loud enough
        /// to read as on/off without colliding with the chip's text.
        /// Prototype CSS sets `--op-selected-chip-fill: 0.14`. The
        /// earlier 0.22 was strong enough that selected chips read like
        /// filled buttons rather than soft toggles, dragging the popover
        /// toward "loaded" — the prototype's quieter 0.14 keeps the
        /// on/off signal without competing with primary CTAs.
        static let selectedChipFill: Double = 0.14

        /// Quiet outline used by inactive chip strokes and divider rules
        /// inside picker grids. Quieter than `borderIdle`. Was 0.25
        /// hardcoded across three pickers.
        static let mutedStroke: Double = 0.25

        /// «Loud overlay» — on-overlay text and gradients on the
        /// fullscreen alert. Was 0.85 / 0.9 hardcoded.
        static let loudOverlay: Double = 0.85
        static let nearOpaque: Double = 0.9
    }
}
