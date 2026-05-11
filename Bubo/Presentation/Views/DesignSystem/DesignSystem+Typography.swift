import SwiftUI

extension DS {
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
}
