import SwiftUI

// MARK: - Midnight
// Author: Bubo Team
// Cinematic void — Apple Midnight hardware color brought to UI.
// Sharp brutalist corners, ultra-thin materials, no separators.
// Content floats in a near-black abyss. Maximum drama, minimum chrome.

extension SkinCatalog {
    static let midnight = SkinDefinition(
        id: "midnight",
        displayName: "Midnight",
        author: "Bubo",
        // Muted indigo — stars through atmospheric haze
        accentColor: Color(red: 0.35, green: 0.46, blue: 0.75),
        // Near-black with blue shift — deep void
        surfaceTint: Color(red: 0.01, green: 0.02, blue: 0.08),
        surfaceTintOpacity: 0.35,
        // Bottom glow — city lights on the horizon
        backgroundGradient: SkinGradient(
            colors: [
                .clear,
                Color(red: 0.10, green: 0.12, blue: 0.25).opacity(0.12),
                Color(red: 0.16, green: 0.18, blue: 0.35).opacity(0.18),
            ],
            style: .linear(startPoint: .top, endPoint: .bottom)
        ),
        previewColors: [
            Color(red: 0.08, green: 0.10, blue: 0.20),
            Color(red: 0.25, green: 0.32, blue: 0.55),
        ],
        prefersDarkTint: true,
        secondaryAccent: Color(red: 0.28, green: 0.38, blue: 0.62),
        // Solid — stark, minimal chrome in darkness
        buttonStyle: .solid,
        // Rectangle — cinematic, brutalist, Kubrick-esque
        buttonShape: .rectangle,
        // Warm amber toolbar — a candle in the dark
        toolbarTint: Color(red: 0.65, green: 0.55, blue: 0.40),
        // Ultra-thin — maximum darkness, minimum frosting
        barMaterial: .ultraThin,
        barTint: Color(red: 0.10, green: 0.12, blue: 0.25),
        barTintOpacity: 0.14,
        platterMaterial: .thin,
        platterTint: Color(red: 0.08, green: 0.10, blue: 0.20),
        platterTintOpacity: 0.10,
        // SF Pro — neutral, disappears in the dark
        fontDesign: .default,
        fontWeight: .regular,
        headlineFontWeight: .semibold,
        // Monochrome — no color noise, just light and shadow
        sfSymbolRendering: .monochrome,
        sfSymbolWeight: .light,
        // Outlined — thin glowing outlines in the void
        badgeStyle: .outlined,
        // None — borders dissolve in darkness
        separatorStyle: .none
    )
}
