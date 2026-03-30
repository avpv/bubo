import SwiftUI

// MARK: - Arctic
// Author: Bubo Team
// Fresh snowfall — crisp ice-blue, maximum brightness, minimal chrome.
// Glass surfaces are frosted windowpanes. Everything is lightweight,
// transparent, crystalline. The opposite of Midnight.

extension SkinCatalog {
    static let arctic = SkinDefinition(
        id: "arctic",
        displayName: "Arctic",
        author: "Bubo",
        // Bright cyan — icy, electric, crisp
        accentColor: Color(red: 0.22, green: 0.65, blue: 0.88),
        // Near-invisible tint — Arctic is about openness
        surfaceTint: Color(red: 0.06, green: 0.12, blue: 0.16),
        surfaceTintOpacity: 0.05,
        // Very subtle top-down — overcast arctic sky
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.20, green: 0.50, blue: 0.72).opacity(0.08),
                Color(red: 0.12, green: 0.30, blue: 0.45).opacity(0.04),
            ],
            style: .linear(startPoint: .top, endPoint: .bottom)
        ),
        previewColors: [
            Color(red: 0.22, green: 0.65, blue: 0.88),
            Color(red: 0.62, green: 0.85, blue: 0.96),
        ],
        prefersDarkTint: false,
        // Light frost blue for glass
        secondaryAccent: Color(red: 0.38, green: 0.72, blue: 0.90),
        // Glass — frosted, airy, crystalline
        buttonStyle: .glass,
        buttonTint: Color(red: 0.18, green: 0.55, blue: 0.78),
        buttonTintOpacity: 0.18,
        // Lavender-ice toolbar — triadic complement
        toolbarTint: Color(red: 0.55, green: 0.50, blue: 0.75),
        // Thin bars — icy, minimal weight
        barMaterial: .thin,
        barTint: Color(red: 0.18, green: 0.42, blue: 0.58),
        barTintOpacity: 0.06,
        platterMaterial: .thin,
        platterTint: Color(red: 0.14, green: 0.38, blue: 0.52),
        platterTintOpacity: 0.04,
        // Rounded + light weight — delicate ice crystals
        fontDesign: .rounded,
        fontWeight: .regular,
        headlineFontWeight: .medium,
        // Hierarchical + light — crystalline, translucent icons
        sfSymbolRendering: .hierarchical,
        sfSymbolWeight: .light,
        // Tinted — soft frost badges
        badgeStyle: .tinted,
        // Subtle — barely-visible ice lines
        separatorStyle: .subtle,
        separatorOpacity: 0.2
    )
}
