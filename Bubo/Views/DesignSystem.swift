import SwiftUI

// MARK: - Design Tokens

/// Centralized design system for consistent spacing, sizing, typography, and colors.
enum DS {

    // MARK: Spacing Scale (4-point grid)

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        /// Birman: pills/badges inherit the 4-pt rhythm (was 6 → off-grid).
        static let pillVertical: CGFloat = 4
        /// Birman: pills/badges inherit the 4-pt rhythm (was 10 → off-grid).
        static let pillHorizontal: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
        /// 4-pt grid extension for hero-scale elements (fullscreen alert
        /// buttons, footer spacers on the alert screen).
        static let xxxxl: CGFloat = 40

        /// Single outer margin used by every top-level surface (header, footer,
        /// event list, color filter, quick actions, world clock) so all content
        /// hangs on one vertical axis. HIG: consistent layout margins.
        /// Birman: modular grid — one column, one line on the left.
        static let contentMargin: CGFloat = lg
    }

    // MARK: Density

    /// Vertical breathing-room mode for list rows. `comfortable` uses the
    /// canonical `Spacing.sm` vertical padding (default for short lists);
    /// `compact` halves it to `Spacing.xs`, used when the row count climbs
    /// past ~10 so the user can sweep the whole queue without scrolling.
    /// Birman: «more tasks — denser rhythm»; bookkeeping density should
    /// follow data density, not be a global toggle in settings.
    enum Density {
        case comfortable
        case compact

        /// Vertical padding inside a backlog/task row at this density.
        /// Horizontal padding stays constant — only vertical breathing-room
        /// changes — so the column edges don't shift when rows densify.
        var rowVerticalPadding: CGFloat {
            switch self {
            case .comfortable: return Spacing.sm
            case .compact:     return Spacing.xs
            }
        }

        /// Pick density automatically from a row count. Threshold (10) is
        /// the count at which the standard popover starts requiring scroll
        /// at `comfortable` — densifying buys back the headroom.
        static func auto(rowCount: Int, threshold: Int = 10) -> Density {
            rowCount >= threshold ? .compact : .comfortable
        }
    }

    // MARK: Hero / Fullscreen Alert

    /// Dedicated spacing tokens for the fullscreen meeting alert.
    /// Kept as an intentional sub-scale (named constants rather than an
    /// ad-hoc sum of `xxxl + sm`) so the layout reads as design intent,
    /// not arithmetic. Birman: "magical constants" → named intent.
    enum Alert {
        /// Horizontal padding for Join-style action buttons.
        static let joinButtonPadding: CGFloat = 40
        /// Horizontal padding for the Dismiss pill — wider so the text
        /// breathes against the hero typography around it.
        static let dismissButtonPadding: CGFloat = 60
        /// Bottom spacer under the action stack on the alert screen.
        static let footerSpacer: CGFloat = 60
        /// Horizontal padding for the hero event title.
        static let titlePadding: CGFloat = 40
    }

    // MARK: Popover Dimensions

    enum Popover {
        static let width: CGFloat = 360
        static let height: CGFloat = 600
        static let timerHeight: CGFloat = 440
        static let dateSuggestionsWidth: CGFloat = 240
    }

    // MARK: Grid Layout

    enum Grid {
        static let skinCardMinWidth: CGFloat = 94
        static let skinCardSpacing: CGFloat = 8
    }

    // MARK: Settings Window

    enum Settings {
        static let sidebarWidth: CGFloat = 200
        static let detailWidth: CGFloat = 500
        static let width: CGFloat = sidebarWidth + detailWidth
        static let minHeight: CGFloat = 480
        static let idealHeight: CGFloat = 540
    }

    // MARK: Empty State

    // MARK: Typography
    //
    // One scale, four steps. Birman: «one typographic rhythm».
    //
    //   display   — `.largeTitle` — fullscreen alert hero only.
    //   headline  — `.title3`     — popover headers, page titles, hero card titles.
    //   body      — `.body`       — default running text, primary row labels.
    //   subhead   — `.footnote`   — secondary metadata, hints, badges, day-section labels.
    //
    // No `.caption*`, `.callout`, `.subheadline`, or `.headline` outside this enum.
    // All helpers thread the active skin's font design (rounded by default), so
    // surfaces inherit one voice without each view constructing `.system(...)` by hand.

    enum Typography {
        static let bodyLineSpacing: CGFloat = 3

        // MARK: Semantic ramp

        /// Hero scale — fullscreen alert only.
        static func display(skin: SkinDefinition, weight: Font.Weight? = nil) -> Font {
            .system(.largeTitle, design: skin.resolvedFontDesign, weight: weight ?? skin.resolvedHeadlineFontWeight)
        }

        /// Section / page / card title.
        static func headline(skin: SkinDefinition, weight: Font.Weight? = nil) -> Font {
            .system(.title3, design: skin.resolvedFontDesign, weight: weight ?? skin.resolvedHeadlineFontWeight)
        }

        /// Default running text.
        static func body(skin: SkinDefinition, weight: Font.Weight? = nil) -> Font {
            .system(.body, design: skin.resolvedFontDesign, weight: weight ?? skin.resolvedFontWeight)
        }

        /// Quiet secondary text — metadata, hints, badges.
        static func subhead(skin: SkinDefinition, weight: Font.Weight = .regular) -> Font {
            .system(.footnote, design: skin.resolvedFontDesign, weight: weight)
        }

        // MARK: Hero numerics

        /// Variable-weight countdown for `FullScreenAlertView`. Weight grows
        /// from `.medium` (≥ 5 min) through `.semibold` / `.bold` to `.heavy`
        /// in the last minute, so urgency is conveyed by *weight* in addition
        /// to colour — readable under `Reduce Motion + Increased Contrast`,
        /// which strips animation and softens the red.
        ///
        /// Always uses SF Pro Rounded (`.rounded`) with `monospacedDigit()`
        /// so digits don't jitter at 1 Hz refresh — the «friendly» face Apple
        /// uses in Clock / Fitness countdown UI.
        static func heroCountdown(secondsRemaining: Int) -> Font {
            .system(.largeTitle, design: .rounded, weight: countdownWeight(for: secondsRemaining))
                .monospacedDigit()
        }

        // MARK: Inline numerics & quiet voices

        /// Numeric facts inside running UI: «14 tasks», «Done by 17:30»,
        /// «4 h 32 min», «1 h», «→ 15:30». Same size class as `subhead`
        /// so it sits on the same baseline, but `.medium` weight and
        /// `monospacedDigit()` so columns of digits read as *data* —
        /// distinguishable at a glance from the prose around them.
        ///
        /// Birman: «numbers are a different category by nature», they need
        /// their own voice; otherwise «14 tasks» is indistinguishable from «Don't fit».
        static func metric(skin: SkinDefinition) -> Font {
            .system(.footnote, design: skin.resolvedFontDesign, weight: .medium)
                .monospacedDigit()
        }

        /// Section labels above grouped lists — «TODAY», «FREE», «BACKLOG».
        /// Tracked uppercase caption, lighter than body, so the eye groups
        /// the rows below it without the label competing with their content.
        /// Pairs with macOS HIG's grouped-list section header treatment.
        static func label(skin: SkinDefinition) -> Font {
            .system(.caption2, design: skin.resolvedFontDesign, weight: .medium)
        }

        /// «Speech of the machine» — subtext under `SmartActions`, ghost-slot
        /// hints («→ 15:30»), duration guesses («~30m»), keyboard-shortcut
        /// hints («⌘K»). Monospaced footnote in tertiary so the user learns
        /// «this voice is the computer thinking out loud», never the user's
        /// own input.
        static let machineHint: Font = .footnote.monospaced()

        /// Rounded, equal-width-digit face for the in-popover ring timer.
        /// Hero numerics share the SF Rounded face with the alert; weight is
        /// fixed (`.bold`) because the ring already conveys progress.
        static func heroRingDigit(size: CGFloat) -> Font {
            .system(size: size, weight: .bold, design: .rounded)
                .monospacedDigit()
        }

        /// Unit suffix paired with `heroRingDigit` (the «h / m / s» glyphs).
        /// Sized as a fraction of the digit size so the ratio stays
        /// constant when the ring scales for multi-day events.
        static func heroRingUnit(size: CGFloat, design: Font.Design) -> Font {
            .system(size: size * 0.45, weight: .medium, design: design)
        }

        // MARK: Internals

        /// Mapping from time-remaining → font weight. Five buckets so the
        /// transitions are perceptible without feeling twitchy.
        static func countdownWeight(for secondsRemaining: Int) -> Font.Weight {
            switch secondsRemaining {
            case ...60:    return .heavy     // last minute — pure urgency
            case ...120:   return .bold
            case ...300:   return .semibold  // 5-minute threshold
            case ...600:   return .medium
            default:       return .regular   // > 10 min — calm
            }
        }
    }

    // MARK: Component Sizes

    enum Size {
        static let accentBarWidth: CGFloat = 4
        static let accentBarHeight: CGFloat = 28
        static let eventRowMinHeight: CGFloat = 36
        static let backlogRowHeight: CGFloat = 44
        static let headerHeight: CGFloat = 48
        static let actionFooterHeight: CGFloat = 48
        static let timeColumnWidth: CGFloat = 84
        static let datePillWidth: CGFloat = 54
        static let timePillWidth: CGFloat = 52
        static let controlHeight: CGFloat = 28
        static let focusRingWidth: CGFloat = 2
        static let iconSmall: CGFloat = 12
        static let iconMedium: CGFloat = 14
        static let iconLarge: CGFloat = 16
        static let headerIcon: CGFloat = 20
        static let cornerRadius: CGFloat = 12
        /// Inline highlight / subtle-fill surface radius used for hints,
        /// drop targets, inline edit forms and search rows that live
        /// *inside* a larger `cornerRadius`-shaped card. Unifies the
        /// previously hard-coded 6/8 values scattered across the codebase.
        /// Birman: one rhythm of radii — 12 (cards) / 8 (inline) / 20 (pills).
        static let subtleCornerRadius: CGFloat = 8
        static let badgeCornerRadius: CGFloat = 20
        static let syncIndicatorSize: CGFloat = 14
        static let todayDotSize: CGFloat = 6

        // Timer
        static let timerRingDiameter: CGFloat = 180
        static let timerRingStrokeWidth: CGFloat = 4
        static let timerCheckmarkSize: CGFloat = 36

        // Alert
        static let alertIconSize: CGFloat = 60

        // Preview cards (settings UI)
        static let previewCardRadius: CGFloat = 6
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
        /// Was 0.22 hardcoded across three pickers.
        static let selectedChipFill: Double = 0.22

        /// Quiet outline used by inactive chip strokes and divider rules
        /// inside picker grids. Quieter than `borderIdle`. Was 0.25
        /// hardcoded across three pickers.
        static let mutedStroke: Double = 0.25

        /// «Loud overlay» — on-overlay text and gradients on the
        /// fullscreen alert. Was 0.85 / 0.9 hardcoded.
        static let loudOverlay: Double = 0.85
        static let nearOpaque: Double = 0.9
    }

    // MARK: Shadows

    enum Shadows {
        // Alert/fullscreen
        static let glowRadius: CGFloat = 20
        static let buttonRadius: CGFloat = 12

        // Toast — sits between the Tasks-block chrome (`shadowRadius=16`,
        // `shadowY=8`) and the full-screen alert (`glowRadius=20`).
        // 18/9 reads as «slightly above the card» without colliding with
        // the alert depth. Earlier 20/10 made toast indistinguishable
        // from a fullscreen alert in shadow alone.
        static let toastRadius: CGFloat = 18
        static let toastY: CGFloat = 9
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
        /// 0.92 reads as a satisfying squish without becoming twitchy at
        /// 60Hz refresh.
        static let pressedIconScale: CGFloat = 0.92
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

    // MARK: Semantic Colors (adaptive, respects appearance & accessibility)

    enum Colors {
        // Surface colors — adapt to light/dark and vibrancy
        static let surfacePrimary = Color(nsColor: .windowBackgroundColor)
        static let surfaceSecondary = Color(nsColor: .controlBackgroundColor)
        static let surfaceElevated = Color(nsColor: .underPageBackgroundColor)

        // Text colors — semantic hierarchy
        static let textPrimary = Color(nsColor: .labelColor)
        static let textSecondary = Color(nsColor: .secondaryLabelColor)
        static let textTertiary = Color(nsColor: .tertiaryLabelColor)
        static let textQuaternary = Color(nsColor: .quaternaryLabelColor)

        // Accent & interactive
        static let accent = Color.accentColor
        static let accentSubtle = Color.accentColor.opacity(0.12)

        // Semantic status
        static let success = Color(nsColor: .systemGreen)
        static let warning = Color(nsColor: .systemOrange)
        static let error = Color(nsColor: .systemRed)
        static let info = Color(nsColor: .systemBlue)

        // Separator & borders
        static let separator = Color(nsColor: .separatorColor)
        static let border = Color(nsColor: .separatorColor).opacity(0.5)

        // Overlay / fullscreen alert — contrast-aware
        static let overlayBackground = Color.black
        static let onOverlay = Color.white

        // Hover & selection states
        static let hoverFill = Color(nsColor: .labelColor).opacity(0.06)
        static let selectedFill = Color.accentColor.opacity(0.1)

        /// Badge/tag backgrounds — adaptive to accessibility contrast setting.
        static func badgeFill(_ tint: Color, highContrast: Bool = false) -> Color {
            tint.opacity(highContrast ? 0.22 : 0.12)
        }

        // Recipe category dot palette (10 distinct hues)
        static let categoryPalette: [Color] = [
            Color(nsColor: .systemBlue),    // focus
            Color(nsColor: .systemIndigo),  // planning
            Color(nsColor: .systemRed),     // deadlines
            Color(nsColor: .systemTeal),    // meetings
            Color(nsColor: .systemGreen),   // energy
            Color(nsColor: .systemOrange),  // habits
            Color(nsColor: .systemPurple),  // projects
            Color(nsColor: .systemYellow),  // adapt
            Color(nsColor: .systemPink),    // workouts
            Color(nsColor: .systemGray),    // advanced
        ]

        // Calendar-specific
        static let calendarLabel = Color(nsColor: .systemBlue)
    }

    // MARK: Materials (vibrancy)

    enum Materials {
        /// Intentionally ultraThin for maximum translucency on fullscreen overlays.
        static let overlay: Material = .ultraThinMaterial
    }

    // MARK: Event Color Tags

    static let defaultEventColor: Color = .gray

    /// Returns white or black depending on which contrasts better against the given background color.
    static func contrastingForeground(for color: Color) -> Color {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let r = nsColor.redComponent
        let g = nsColor.greenComponent
        let b = nsColor.blueComponent
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.55 ? .black : .white
    }

    // MARK: Urgency Colors

    static func urgencyColor(minutesUntil: Int, skin: SkinDefinition) -> Color {
        if minutesUntil <= 5 { return skin.resolvedDestructiveColor }
        if minutesUntil <= 15 { return skin.resolvedWarningColor }
        return skin.resolvedSuccessColor
    }

    // MARK: Countdown Colors

    static func countdownColor(secondsRemaining: Int, skin: SkinDefinition) -> Color {
        if secondsRemaining <= 120 { return skin.resolvedDestructiveColor }
        if secondsRemaining <= 300 { return skin.resolvedWarningColor }
        return skin.resolvedTextPrimary
    }

    // MARK: Snooze Options

    struct SnoozeOption: Identifiable {
        let id: Int
        let minutes: Int
        let label: String

        init(_ minutes: Int) {
            self.id = minutes
            self.minutes = minutes
            self.label = DS.formatMinutes(minutes)
        }
    }

    static let snoozeOptions: [SnoozeOption] = [
        SnoozeOption(2),
        SnoozeOption(5),
        SnoozeOption(10),
        SnoozeOption(15),
        SnoozeOption(20),
    ]

    // MARK: Ordinal Formatting

    static func formatOrdinal(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: Time Formatting

    static func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m == 0 ? "\(h)\u{00A0}h" : "\(h)\u{00A0}h\u{00A0}\(m)\u{00A0}min"
        }
        return "\(minutes)\u{00A0}min"
    }

    // MARK: Shared Formatters

    /// HIG: Respect user's locale time format (12h vs 24h).
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    /// HIG: Use locale-aware formatting for day section headers.
    static let daySectionFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return f
    }()

    /// Short companion to `daySectionFormatter` — abbreviated weekday
    /// + day + abbreviated month. Used to follow «Today» / «Tomorrow»
    /// in the day-section header so the actual date stays on screen
    /// (e.g. «Today \u{00B7} Tue, 6 May»). Locale-aware — order and
    /// punctuation come from the system formatter.
    static let daySectionShortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f
    }()
}

// MARK: - Haptic Feedback (macOS Force Touch Trackpad)

/// HIG: Use appropriate haptic feedback patterns.
/// - `tap()`: Light feedback for standard button actions (generic pattern).
/// - `impact()`: Stronger feedback for significant state changes (levelChange).
/// - `alignment()`: For drag/alignment guides only (alignment pattern).
enum Haptics {
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic, performanceTime: .default
        )
    }

    static func impact() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .levelChange, performanceTime: .default
        )
    }

    static func alignment() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment, performanceTime: .default
        )
    }
}

// MARK: - Elevation Modifier

extension View {
    /// Apply a depth plane to the surface. The modifier is the single
    /// path through which `DS.Elevation`'s `radius` / `y` / `color`
    /// recipe reaches a SwiftUI `.shadow(...)` call — no per-call-site
    /// arithmetic, no skin field lookups in views.
    ///
    /// Always pass the active skin so per-skin shadow weight (the
    /// difference between e.g. Sierra and Midnight) carries through.
    /// Z0 is intentionally a no-op — it exists so every surface can
    /// declare its plane explicitly, even when it casts nothing.
    func elevation(_ level: DS.Elevation, skin: SkinDefinition) -> some View {
        self.shadow(
            color: level.color(skin: skin),
            radius: level.radius(skin: skin),
            y: level.y(skin: skin)
        )
    }
}

// MARK: - Motion-Aware Entrance Modifier

/// Replaces the repeated `appeared` + `onAppear` boilerplate across views.
/// Respects `accessibilityReduceMotion` — skips animation when enabled.
struct StaggeredEntrance: ViewModifier {
    var index: Int = 0
    var offsetY: CGFloat = DS.Spacing.sm

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : offsetY)
            .scaleEffect(appeared || reduceMotion ? 1.0 : 0.96)
            .onAppear {
                guard !reduceMotion else {
                    appeared = true
                    return
                }
                withAnimation(DS.Animation.staggered(index: index)) {
                    appeared = true
                }
            }
    }
}

extension View {
    /// Staggered entrance animation — respects Reduce Motion.
    func staggeredEntrance(index: Int = 0, offsetY: CGFloat = 8) -> some View {
        modifier(StaggeredEntrance(index: index, offsetY: offsetY))
    }
}

// MARK: - Scroll Transition Modifier

extension View {
    /// Applies a scroll-aware transition: items fade/scale as they enter/exit the visible area.
    func eventScrollTransition() -> some View {
        self.scrollTransition(.animated(DS.Animation.smoothSpring)) { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : DS.Opacity.tertiaryText)
                .scaleEffect(phase.isIdentity ? 1 : 0.94, anchor: .leading)
                .offset(x: phase.isIdentity ? 0 : phase.value * -DS.Spacing.sm)
        }
    }
}

// MARK: - Motion-Aware Animation Modifier

extension View {
    /// Wraps `.animation()` to become a no-op when Reduce Motion is active.
    func motionAwareAnimation<V: Equatable>(
        _ animation: Animation,
        value: V,
        reduceMotion: Bool
    ) -> some View {
        self.animation(
            reduceMotion ? .easeOut(duration: 0.01) : animation,
            value: value
        )
    }
}

// MARK: - Shared Section-Header Typography

extension Text {
    /// Single typographic voice for quiet, in-surface section headers
    /// (form section labels, day-group headers in the timeline, any
    /// subhead that guides the eye without shouting).
    ///
    /// Birman: one scale — `SectionLabel` and `DaySectionHeader` are the
    /// same typographic object, not two look-alikes. Centralising the
    /// style here guarantees they never drift apart.
    ///
    /// 2026 update: dropped uppercase + `tracking(0.4)`. Cap-height + letter
    /// spacing made these read like 1990s product chrome ("PROJECTS  ·
    /// TODAY"); a quiet semibold subhead in mixed case sits inside the
    /// content rather than shouting from above it. Step is `.footnote`
    /// (the smallest of the four-step ramp), not `.caption`, because
    /// `.caption` is no longer in the typographic ramp.
    func sectionHeaderStyle() -> some View {
        self.font(.footnote.weight(.semibold))
    }
}

// MARK: - Shared Section Label

/// Uniform section-label treatment used by form surfaces (AddEventView) and
/// any other view that needs a quiet, in-surface section divider.
///
/// Birman: within one surface, section titles are quiet subheads, not
/// headlines — they guide the eye without shouting. Same typographic voice
/// as `DaySectionHeader` via `sectionHeaderStyle()`.
struct SectionLabel: View {
    let text: String

    @Environment(\.activeSkin) private var skin

    var body: some View {
        Text(text)
            .sectionHeaderStyle()
            .foregroundStyle(skin.resolvedTextTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Adaptive Badge Background

/// A badge background that automatically adapts to High Contrast accessibility setting
/// and respects the active skin's badge style.
struct AdaptiveBadgeFill: ViewModifier {
    let tint: Color

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.activeSkin) private var skin

    func body(content: Content) -> some View {
        switch skin.badgeStyle {
        case .tinted:
            content.background(
                DS.Colors.badgeFill(tint, highContrast: contrast == .increased)
            )
        case .filled:
            content
                .foregroundStyle(DS.contrastingForeground(for: tint))
                .background(tint.opacity(contrast == .increased ? 0.9 : 0.75))
        case .outlined:
            content
                .background(Color.clear)
                .overlay(
                    Capsule()
                        .strokeBorder(tint.opacity(contrast == .increased ? 0.8 : 0.5), lineWidth: 1)
                )
        }
    }
}

extension View {
    func adaptiveBadgeFill(_ tint: Color) -> some View {
        modifier(AdaptiveBadgeFill(tint: tint))
    }
}

// MARK: - Navigation Home Environment

private struct NavigateHomeKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var navigateHome: (() -> Void)? {
        get { self[NavigateHomeKey.self] }
        set { self[NavigateHomeKey.self] = newValue }
    }
}

// MARK: - Reusable Header

/// Standard header bar used across popover views.
/// Material is determined by the active skin's `barMaterial` setting.
struct PopoverHeader: View {
    var title: String? = nil
    /// Optional second line rendered under `title`. When set, the title
    /// switches from a centered single-line layout to a left-aligned
    /// stacked pair (title + subtitle), matching the menu bar's
    /// «date over meta» rhythm. Other surfaces leave it nil and keep
    /// the existing centered behaviour bit-for-bit.
    var subtitle: String? = nil
    var showBack: Bool = false
    /// HIG: Back button should display the title of the previous screen.
    var backLabel: String = "Back"
    var onBack: (() -> Void)? = nil
    var trailing: AnyView? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.activeSkin) private var skin

    /// HIG: Navigation bar pattern — back button leading, title flexible in the
    /// middle, trailing items trailing. Uses a plain HStack with layout priorities
    /// instead of a ZStack so the title cannot collide with trailing indicators
    /// when both sides grow.
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.sm) {
                // Leading: back button OR owl icon (mutually exclusive — one symbol
                // at a time, not two).
                Group {
                    if showBack {
                        Button {
                            Haptics.tap()
                            onBack?()
                        } label: {
                            Label(backLabel, systemImage: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.escape, modifiers: [])
                    } else {
                        OwlIcon(size: DS.Size.headerIcon)
                            .foregroundStyle(skin.accentColor)
                    }
                }
                .layoutPriority(0)

                if let title, let subtitle {
                    // Two-line stacked layout — used by the menu bar
                    // «Today» header so the date and the day-meta line up
                    // on the leading edge instead of fighting for the
                    // visual centre.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(DS.Typography.headline(skin: skin))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(skin.resolvedTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(2)
                    .accessibilityElement(children: .combine)
                } else {
                    Spacer(minLength: DS.Spacing.xs)

                    // Title — flexible, truncates if space runs out.
                    if let title {
                        Text(title)
                            .font(DS.Typography.headline(skin: skin))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(2)
                    }

                    Spacer(minLength: DS.Spacing.xs)
                }

                // Trailing: optional status / action controls.
                if let trailing {
                    trailing
                        .layoutPriority(1)
                } else if showBack {
                    // Balance the back button so the title stays centered even
                    // without any trailing content.
                    Color.clear.frame(width: DS.Size.iconLarge, height: 1)
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .frame(minHeight: DS.Size.headerHeight)
            .skinBarBackground(skin)

            SkinSeparator()
        }
    }
}

// MARK: - Unified Action Button Style

enum ActionButtonRole {
    case primary
    case secondary
    case destructive
}

enum ActionButtonSize {
    case flexible // minWidth: 100, lg padding
    case compact  // padding: sm, xs
    case regular  // fixedSize, padding: md, sm
}

struct ActionButtonStyle: ButtonStyle {
    var role: ActionButtonRole = .primary
    var size: ActionButtonSize = .flexible

    @Environment(\.activeSkin) private var skin

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(skin.resolvedFontWeight)
            .font(.system(.body, design: skin.resolvedFontDesign))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, size == .compact ? 0 : verticalPadding)
            .frame(height: size == .compact ? DS.Size.controlHeight : nil)
            .frame(minWidth: size == .flexible ? 100 : nil)
            .fixedSize(horizontal: size == .regular, vertical: false)
            .contentShape(buttonContentShape)
            .background(backgroundView(isPressed: configuration.isPressed))
            .foregroundStyle(foregroundStyle)
            .clipShape(buttonClipShape)
            .overlay(buttonStrokeOverlay)
            .shadow(
                color: shadowColor(isPressed: configuration.isPressed),
                radius: configuration.isPressed ? skin.shadowRadius * 0.25 : (role == .primary ? skin.hoverShadowRadius : skin.shadowRadius),
                y: configuration.isPressed ? skin.shadowY * 0.25 : (role == .primary ? skin.hoverShadowY * 0.67 : skin.shadowY * 0.5)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(skin.resolvedMicroAnimation, value: configuration.isPressed)
    }

    private var skinAccent: Color {
        skin.isClassic ? DS.Colors.accent : skin.resolvedButtonAccentColor
    }

    // MARK: Shape

    private var buttonContentShape: AnyShape {
        switch skin.buttonShape {
        case .capsule:     AnyShape(Capsule())
        case .roundedRect: AnyShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius))
        case .rectangle:   AnyShape(Rectangle())
        }
    }

    private var buttonClipShape: AnyShape { buttonContentShape }

    @ViewBuilder
    private var buttonStrokeOverlay: some View {
        let opacity = role == .primary ? 0.3 : 0.06
        let width: CGFloat = role == .primary ? 1.0 : 0.5
        switch skin.buttonShape {
        case .capsule:
            Capsule()
                .strokeBorder(.white.opacity(opacity), lineWidth: width)
        case .roundedRect:
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius)
                .strokeBorder(.white.opacity(opacity), lineWidth: width)
        case .rectangle:
            Rectangle()
                .strokeBorder(.white.opacity(opacity), lineWidth: width)
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .flexible: return DS.Spacing.lg
        case .regular: return DS.Spacing.md
        case .compact: return DS.Spacing.sm
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .flexible, .regular: return DS.Spacing.sm
        case .compact: return DS.Spacing.xs
        }
    }

    @ViewBuilder
    private func backgroundView(isPressed: Bool) -> some View {
        switch role {
        case .primary:
            switch skin.buttonStyle {
            case .gradient:
                LinearGradient(
                    colors: isPressed
                        ? [skinAccent.opacity(0.75), skin.resolvedButtonSecondaryAccent.opacity(0.75)]
                        : [skinAccent, skin.resolvedButtonSecondaryAccent],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .glass:
                ZStack {
                    Rectangle().fill(skin.resolvedButtonMaterial)
                    skin.resolvedButtonTint.opacity(isPressed ? skin.buttonTintOpacity * 0.67 : skin.buttonTintOpacity)
                }
            case .solid:
                if isPressed {
                    skinAccent.opacity(0.8)
                } else {
                    skinAccent
                }
            }
        case .secondary:
            ZStack {
                Rectangle().fill(skin.resolvedButtonMaterial)
                if isPressed {
                    Color.primary.opacity(0.06)
                }
            }
        case .destructive:
            ZStack {
                Rectangle().fill(skin.resolvedButtonMaterial)
                if isPressed {
                    skin.resolvedDestructiveColor.opacity(0.08)
                }
            }
        }
    }

    private var foregroundStyle: Color {
        switch role {
        case .primary:
            // Explicit button color from skin takes priority
            if let custom = skin.buttonColor { return custom }
            if skin.buttonStyle == .glass { return skinAccent }
            // HIG: Ensure text contrast against accent background.
            // Use white on dark accents, primary label on light accents.
            return Self.contrastingForeground(for: skinAccent)
        case .secondary: return skin.resolvedTextPrimary
        case .destructive: return skin.resolvedDestructiveColor
        }
    }

    private static func contrastingForeground(for color: Color) -> Color {
        DS.contrastingForeground(for: color)
    }

    private func shadowColor(isPressed: Bool) -> Color {
        if isPressed { return .clear }
        switch role {
        case .primary: return skinAccent.opacity(0.35)
        case .secondary, .destructive: return skin.resolvedShadowColor
        }
    }
}

extension ButtonStyle where Self == ActionButtonStyle {
    static func action(role: ActionButtonRole = .primary, size: ActionButtonSize = .flexible) -> ActionButtonStyle {
        ActionButtonStyle(role: role, size: size)
    }
}

// MARK: - Icon Press Style
//
// `.buttonStyle(.plain)` strips macOS's default press feedback, which is fine
// for chromeless icon buttons (row checkboxes, hover-revealed chevrons) but
// loses the «press registered» physical cue. `IconPressStyle` is the same
// chromeless surface plus a single moment of feedback: the icon squishes 8%
// while the mouse is held, then springs back. No background, no shadow —
// purpose-built for naked-glyph buttons that already live inside a row of
// their own visual treatment.
//
// Pair with `Haptics.tap()` in the action closure for a coherent
// visual + tactile «click» — see `BacklogTaskRow.checkbox`.
struct IconPressStyle: ButtonStyle {
    /// How far down the icon goes while held. Default uses the shared
    /// `DS.Physics.pressedIconScale` token so all chromeless buttons in
    /// the app squish the same amount.
    var pressedScale: CGFloat = DS.Physics.pressedIconScale

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Asymmetric easing — physical fingers accelerate INTO a press
    /// (`.easeIn`) and the spring decelerates OUT (`.easeOut`). A single
    /// `.easeOut` for both directions reads «mechanical»; the asymmetric
    /// pair feels «soft». Evaluation time: SwiftUI sees the new value of
    /// `configuration.isPressed`, so true-direction = press (easeIn),
    /// false-direction = release (easeOut).
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1.0)
            .animation(
                reduceMotion
                    ? nil
                    : (configuration.isPressed
                        ? .easeIn(duration: 0.10)
                        : .easeOut(duration: 0.18)),
                value: configuration.isPressed
            )
    }
}

extension ButtonStyle where Self == IconPressStyle {
    /// Chromeless icon button with a press-scale feedback. Replaces
    /// `.plain` on naked-glyph triggers (checkbox, hover chevrons) where the
    /// click should feel physical without growing chrome.
    static var iconPress: IconPressStyle { IconPressStyle() }
}
