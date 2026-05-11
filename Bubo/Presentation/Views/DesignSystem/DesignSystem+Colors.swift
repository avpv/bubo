import SwiftUI

extension DS {
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
}
