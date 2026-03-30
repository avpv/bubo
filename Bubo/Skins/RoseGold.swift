import SwiftUI

// MARK: - Rose Gold
// Author: Bubo Team
// Warm copper luxury — inspired by Apple hardware finishes and iPhone Rose Gold.
// Apple HIG: warmth and approachability through refined material tones.
// Personality: elegant, premium. Gradient buttons for a polished
// jewel-like quality — copper fading to blush pink.

extension SkinCatalog {
    static let roseGold = SkinDefinition(
        id: "rose_gold",
        displayName: "Rose Gold",
        author: "Bubo",
        // Rich copper-rose — warmer, more saturated
        accentColor: Color(red: 0.82, green: 0.48, blue: 0.44),
        // Warm dark surface — like brushed copper in shadow
        surfaceTint: Color(red: 0.16, green: 0.06, blue: 0.04),
        surfaceTintOpacity: 0.20,
        // Diagonal warm gradient — luxury, movement
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.75, green: 0.38, blue: 0.32).opacity(0.12),
                Color(red: 0.45, green: 0.20, blue: 0.18).opacity(0.07),
                .clear,
            ],
            style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
        ),
        previewColors: [
            Color(red: 0.82, green: 0.48, blue: 0.44),
            Color(red: 0.92, green: 0.65, blue: 0.55),
        ],
        prefersDarkTint: false,
        // Blush pink for button gradient — copper to pink shimmer
        secondaryAccent: Color(red: 0.90, green: 0.60, blue: 0.52),
        // HIG: gradient — premium feel, jewel-like shimmer
        buttonStyle: .gradient,
        // Warm gold toolbar — like gold jewelry paired with rose gold
        toolbarTint: Color(red: 0.75, green: 0.62, blue: 0.38),
        // Warm copper-tinted bars — brushed metal feel
        barTint: Color(red: 0.60, green: 0.35, blue: 0.28),
        barTintOpacity: 0.10,
        // Rose-tinted platters — subtle luxury on surfaces
        platterTint: Color(red: 0.55, green: 0.30, blue: 0.25),
        platterTintOpacity: 0.05
    )
}
