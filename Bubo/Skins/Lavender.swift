import SwiftUI

// MARK: - Lavender
// Author: Bubo Team
// Ethereal violet nebula — inspired by visionOS spatial UI and the dreamy
// quality of twilight. Glass surfaces float like holograms in soft purple mist.
// Everything is light, airy, and otherworldly.

extension SkinCatalog {
    static let lavenderSkin = SkinDefinition(
        id: "lavender",
        displayName: "Lavender",
        author: "Bubo",
        // Rich violet — vivid but not aggressive
        accentColor: Color(red: 0.58, green: 0.38, blue: 0.92),
        // Purple-black mood — deep space
        surfaceTint: Color(red: 0.12, green: 0.06, blue: 0.20),
        surfaceTintOpacity: 0.25,
        // Central radial glow — nebula core
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.42, green: 0.24, blue: 0.75).opacity(0.18),
                Color(red: 0.22, green: 0.12, blue: 0.48).opacity(0.10),
                .clear,
            ],
            style: .radial(center: .center, startRadius: 0, endRadius: 400)
        ),
        previewColors: [
            Color(red: 0.58, green: 0.38, blue: 0.92),
            Color(red: 0.80, green: 0.48, blue: 0.75),
        ],
        prefersDarkTint: false,
        secondaryAccent: Color(red: 0.45, green: 0.28, blue: 0.78),
        // Glass — spatial, holographic, visionOS energy
        buttonStyle: .glass,
        buttonTint: Color(red: 0.48, green: 0.30, blue: 0.78),
        buttonTintOpacity: 0.28,
        // Warm pink toolbar — split-complementary warmth
        toolbarTint: Color(red: 0.80, green: 0.45, blue: 0.65),
        // Thin bars — ethereal, airy weight
        barMaterial: .thin,
        barTint: Color(red: 0.38, green: 0.20, blue: 0.58),
        barTintOpacity: 0.14,
        platterTint: Color(red: 0.32, green: 0.18, blue: 0.52),
        platterTintOpacity: 0.07,
        // Rounded — soft, approachable, dreamy
        fontDesign: .rounded,
        fontWeight: .medium,
        headlineFontWeight: .semibold,
        // Hierarchical with light weight — delicate, gossamer-thin
        sfSymbolRendering: .hierarchical,
        sfSymbolWeight: .light,
        // Tinted — soft pastel badges, like watercolor
        badgeStyle: .tinted,
        // Subtle — barely-there separators, spatial floating
        separatorStyle: .subtle,
        separatorOpacity: 0.25
    )
}
