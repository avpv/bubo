import SwiftUI

// MARK: - Sierra
// Author: Bubo Team
// Warm earth and terracotta — California golden hills meet desert sunset.
// Apple HIG: natural warmth, organic color grounding.
// Personality: grounded, adventurous. Gradient buttons with
// a sunset amber-to-clay feel — like golden hour light.

extension SkinCatalog {
    static let sierra = SkinDefinition(
        id: "sierra",
        displayName: "Sierra",
        author: "Bubo",
        // Rich amber — warmer and deeper, like golden hour
        accentColor: Color(red: 0.82, green: 0.58, blue: 0.25),
        // Warm brown-black surface — red desert earth
        surfaceTint: Color(red: 0.14, green: 0.08, blue: 0.02),
        surfaceTintOpacity: 0.22,
        // Radial from top-trailing — warm light source, like sunset
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.62, green: 0.35, blue: 0.12).opacity(0.14),
                Color(red: 0.38, green: 0.18, blue: 0.06).opacity(0.08),
                .clear,
            ],
            style: .radial(center: .topTrailing, startRadius: 0, endRadius: 450)
        ),
        previewColors: [
            Color(red: 0.82, green: 0.58, blue: 0.25),
            Color(red: 0.58, green: 0.32, blue: 0.15),
        ],
        prefersDarkTint: false,
        // Deep clay for button gradient — amber to terracotta
        secondaryAccent: Color(red: 0.68, green: 0.38, blue: 0.18),
        // HIG: gradient — warm sunset energy on buttons
        buttonStyle: .gradient,
        // Terracotta/rust toolbar — earthy complement to golden accent
        toolbarTint: Color(red: 0.70, green: 0.42, blue: 0.28),
        // Warm earth-tinted bars — adobe wall feel
        barTint: Color(red: 0.45, green: 0.25, blue: 0.10),
        barTintOpacity: 0.10,
        // Terracotta platters — sun-baked clay surfaces
        platterTint: Color(red: 0.40, green: 0.22, blue: 0.08),
        platterTintOpacity: 0.05,
        fontDesign: .rounded,
        fontWeight: .semibold,
        headlineFontWeight: .bold,
        sfSymbolRendering: .hierarchical,
        sfSymbolWeight: .medium,
        badgeStyle: .filled,
        separatorStyle: .subtle,
        separatorOpacity: 0.4
    )
}
