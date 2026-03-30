import SwiftUI

// MARK: - Lavender
// Author: Bubo Team
// Dreamy violet mist — inspired by iOS purple accents and visionOS spatial UI.
// Apple HIG: gentle, approachable color that supports focus.
// Personality: ethereal, creative. Glass buttons with stronger
// purple mood — like working inside a soft nebula.

extension SkinCatalog {
    static let lavenderSkin = SkinDefinition(
        id: "lavender",
        displayName: "Lavender",
        author: "Bubo",
        // Rich violet — more saturated than before
        accentColor: Color(red: 0.55, green: 0.36, blue: 0.90),
        // Purple-tinted darkness for mood
        surfaceTint: Color(red: 0.10, green: 0.05, blue: 0.18),
        surfaceTintOpacity: 0.22,
        // Radial glow from center — nebula/spotlight feel
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.40, green: 0.22, blue: 0.72).opacity(0.14),
                Color(red: 0.20, green: 0.10, blue: 0.45).opacity(0.08),
                .clear,
            ],
            style: .radial(center: .center, startRadius: 0, endRadius: 400)
        ),
        previewColors: [
            Color(red: 0.55, green: 0.36, blue: 0.90),
            Color(red: 0.78, green: 0.45, blue: 0.72),
        ],
        prefersDarkTint: false,
        secondaryAccent: Color(red: 0.42, green: 0.25, blue: 0.75),
        // HIG: glass — ethereal, spatial feel
        buttonStyle: .glass,
        // Violet tint on glass buttons — dreamy nebula glow
        buttonTint: Color(red: 0.45, green: 0.28, blue: 0.75),
        buttonTintOpacity: 0.25,
        // Warm pink toolbar — split-complementary to violet
        toolbarTint: Color(red: 0.78, green: 0.42, blue: 0.62),
        // Thin bars — ethereal, airy, visionOS-inspired
        barMaterial: .thin,
        // Purple-tinted bars — nebula atmosphere
        barTint: Color(red: 0.35, green: 0.18, blue: 0.55),
        barTintOpacity: 0.12,
        // Violet mist platters — soft, dreamy surfaces
        platterTint: Color(red: 0.30, green: 0.15, blue: 0.50),
        platterTintOpacity: 0.06
    )
}
