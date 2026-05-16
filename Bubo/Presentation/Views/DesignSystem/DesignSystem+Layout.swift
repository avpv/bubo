import SwiftUI

extension DS {
    // MARK: Spacing Scale (4-point grid)

    enum Spacing {
        /// 1-pt nudge — used for hairline icon offsets and sub-pixel
        /// pill tweaks where the next step up (`xxs` = 2) would visibly
        /// over-correct. Off the standard 4-pt grid by design: these
        /// are optical-alignment fixes for SF Symbol baselines, not
        /// regular layout rhythm.
        static let hairline: CGFloat = 1
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
        /// Apple's `xxl` step (48). Used for hero-scale chrome
        /// (fullscreen alert buttons, footer spacers on the alert screen)
        /// and for the headroom around hero numerics. Was 40 — bumped to
        /// 48 to land on Apple's reference grid.
        static let xxxxl: CGFloat = 48
        /// Apple's «section» padding (80). Reserved for full-tile vertical
        /// rhythm on hero / marketing-style surfaces. Bubo's popover-scale
        /// surfaces won't usually reach this size; the token exists so any
        /// future hero pane sits on Apple's grid rather than picking a
        /// random magic number.
        static let section: CGFloat = 80

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

}
