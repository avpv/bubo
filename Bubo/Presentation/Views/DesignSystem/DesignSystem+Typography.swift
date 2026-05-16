import SwiftUI

extension DS {
    // MARK: Typography
    //
    // One Apple-aligned scale. Apple's design system prescribes weights
    // **300 / 400 / 600 / 700** — no weight 500. Surfaces inherit the
    // active skin's font design (SF Pro Text/Display for the Apple-grammar
    // catalog) so views never construct `.system(...)` by hand.
    //
    //   display   — `.largeTitle` — fullscreen alert hero only.
    //   headline  — `.title3`     — popover headers, page titles, hero card titles.
    //   body      — `.body`       — default running text, primary row labels.
    //   subhead   — `.footnote`   — secondary metadata, hints, badges, day-section labels.
    //   caption   — `.caption`    — chrome hints, micro-labels.
    //   micro     — `.caption2`   — tags, kbd-hint badges.
    //
    // No `.callout`, `.subheadline`, or `.headline` outside this enum.

    enum Typography {
        /// Body line-spacing addition. Apple's body line-height is 1.47×
        /// — on macOS HIG 13pt body that lands at ~19pt total, so a +3pt
        /// addition over SwiftUI's default reads correctly.
        static let bodyLineSpacing: CGFloat = 3

        /// Apple's tracking value for body text (17pt web spec, scaled
        /// for the macOS 13pt body). Negative tracking tightens the
        /// glyphs — a key visual signal of the Apple voice.
        static let bodyTracking: CGFloat = -0.16

        /// Apple's tracking value for display headlines.
        static let displayTracking: CGFloat = -0.28

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

        /// Chrome hints, micro-labels under inputs (one step below subhead).
        static func caption(skin: SkinDefinition, weight: Font.Weight = .regular) -> Font {
            .system(.caption, design: skin.resolvedFontDesign, weight: weight)
        }

        /// Tags, kbd-hint badges, sub-glyph micro-affordances.
        static func micro(skin: SkinDefinition, weight: Font.Weight = .semibold) -> Font {
            .system(.caption2, design: skin.resolvedFontDesign, weight: weight)
        }

        // MARK: Hero numerics

        /// Variable-weight countdown for `FullScreenAlertView`. Weight grows
        /// from `.regular` (≥ 10 min) through `.semibold` / `.bold` to
        /// `.heavy` in the last minute, so urgency is conveyed by *weight*
        /// in addition to colour — readable under `Reduce Motion +
        /// Increased Contrast`, which strips animation and softens the red.
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
        /// so it sits on the same baseline, but `.semibold` weight and
        /// `monospacedDigit()` so columns of digits read as *data* —
        /// distinguishable at a glance from the prose around them.
        ///
        /// Apple's «no weight 500» rule: was `.medium`, now `.semibold`.
        static func metric(skin: SkinDefinition) -> Font {
            .system(.footnote, design: skin.resolvedFontDesign, weight: .semibold)
                .monospacedDigit()
        }

        /// Section labels above grouped lists — «TODAY», «FREE», «BACKLOG».
        /// Tracked uppercase caption, lighter than body, so the eye groups
        /// the rows below it without the label competing with their content.
        /// Pairs with macOS HIG's grouped-list section header treatment.
        ///
        /// Apple's «no weight 500» rule: was `.medium`, now `.semibold`.
        static func label(skin: SkinDefinition) -> Font {
            .system(.caption2, design: skin.resolvedFontDesign, weight: .semibold)
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
        ///
        /// Apple's «no weight 500» rule: was `.medium`, now `.semibold`.
        static func heroRingUnit(size: CGFloat, design: Font.Design) -> Font {
            .system(size: size * 0.45, weight: .semibold, design: design)
        }

        // MARK: Internals

        /// Mapping from time-remaining → font weight. Apple's allowed
        /// weights only (no 500). Four buckets so the transitions are
        /// perceptible without feeling twitchy.
        static func countdownWeight(for secondsRemaining: Int) -> Font.Weight {
            switch secondsRemaining {
            case ...60:    return .heavy     // last minute — pure urgency
            case ...120:   return .bold
            case ...300:   return .semibold  // 5-minute threshold
            default:       return .regular   // > 5 min — calm
            }
        }
    }
}

// MARK: - Apple-aligned text modifiers

extension Text {
    /// Apply Apple's body voice: SF Pro Text, regular weight, negative
    /// tracking, and HIG-correct line-spacing. Used wherever the running
    /// text should read as Apple's marketing-site body — not as macOS
    /// system chrome.
    func appleBody() -> some View {
        self.tracking(DS.Typography.bodyTracking)
            .lineSpacing(DS.Typography.bodyLineSpacing)
    }

    /// Apply Apple's display voice: tight negative tracking on hero
    /// headlines. Pair with `DS.Typography.display(...)` or
    /// `.headline(...)`.
    func appleDisplay() -> some View {
        self.tracking(DS.Typography.displayTracking)
    }
}
