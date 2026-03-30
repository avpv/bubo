import SwiftUI

// MARK: - Arctic
// Author: Bubo Team
// Crisp ice-blue — airy, bright, and spacious like fresh snowfall.
// Apple HIG: lightness and clarity, emphasizing content over chrome.
// Personality: clean, bright, minimal. Glass buttons with very low
// tint — like frosted glass on a winter morning.

extension SkinCatalog {
    static let arctic = SkinDefinition(
        id: "arctic",
        displayName: "Arctic",
        author: "Bubo",
        // Bright cyan-blue — icy, crisp
        accentColor: Color(red: 0.20, green: 0.62, blue: 0.85),
        // Almost invisible tint — Arctic is about brightness and openness
        surfaceTint: Color(red: 0.05, green: 0.10, blue: 0.14),
        surfaceTintOpacity: 0.06,
        // Very subtle top-down linear — like overcast arctic sky
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.18, green: 0.48, blue: 0.68).opacity(0.06),
                Color(red: 0.10, green: 0.28, blue: 0.42).opacity(0.03),
            ],
            style: .linear(startPoint: .top, endPoint: .bottom)
        ),
        previewColors: [
            Color(red: 0.20, green: 0.62, blue: 0.85),
            Color(red: 0.60, green: 0.82, blue: 0.95),
        ],
        prefersDarkTint: false,
        // Light frost blue for subtle button glass
        secondaryAccent: Color(red: 0.35, green: 0.70, blue: 0.88),
        // HIG: glass — frosted, airy, light
        buttonStyle: .glass,
        // Cool lavender-ice toolbar — triadic complement to cyan
        toolbarTint: Color(red: 0.52, green: 0.48, blue: 0.72),
        // Thin bars — icy, crystalline, minimal weight
        barMaterial: .thin,
        // Faint ice-blue bar tint — frosted window pane
        barTint: Color(red: 0.15, green: 0.40, blue: 0.55),
        barTintOpacity: 0.05,
        // Thin platters — delicate frost surfaces
        platterMaterial: .thin,
        platterTint: Color(red: 0.12, green: 0.35, blue: 0.50),
        platterTintOpacity: 0.03,
        fontDesign: .rounded,
        fontWeight: .regular,
        headlineFontWeight: .medium,
        sfSymbolRendering: .hierarchical,
        sfSymbolWeight: .light,
        badgeStyle: .tinted,
        separatorStyle: .subtle,
        separatorOpacity: 0.3
    )
}
