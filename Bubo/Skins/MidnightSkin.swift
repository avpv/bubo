import SwiftUI

// MARK: - Midnight
// Author: Bubo Team
// Deep immersive black — Apple Midnight hardware color brought to UI.
// Apple HIG: immersive dark experience with subtle depth.
// Personality: cinematic, stark. Solid buttons for high contrast
// against the deep void — maximum focus on content.

extension SkinCatalog {
    static let midnight = SkinDefinition(
        id: "midnight",
        displayName: "Midnight",
        author: "Bubo",
        // Muted indigo — visible but not bright, like stars through haze
        accentColor: Color(red: 0.32, green: 0.44, blue: 0.72),
        // Almost-black with blue shift — deep void
        surfaceTint: Color(red: 0.01, green: 0.02, blue: 0.06),
        surfaceTintOpacity: 0.30,
        // Bottom glow — like city lights on the horizon at midnight
        backgroundGradient: SkinGradient(
            colors: [
                .clear,
                Color(red: 0.08, green: 0.10, blue: 0.22).opacity(0.10),
                Color(red: 0.14, green: 0.16, blue: 0.32).opacity(0.16),
            ],
            style: .linear(startPoint: .top, endPoint: .bottom)
        ),
        previewColors: [
            Color(red: 0.08, green: 0.10, blue: 0.18),
            Color(red: 0.22, green: 0.30, blue: 0.52),
        ],
        prefersDarkTint: true,
        secondaryAccent: Color(red: 0.25, green: 0.35, blue: 0.58),
        // HIG: solid — stark, minimal chrome in the darkness
        buttonStyle: .solid,
        // Dim warm amber toolbar — like a candle in the dark, complementary warmth
        toolbarTint: Color(red: 0.62, green: 0.52, blue: 0.38)
    )
}
