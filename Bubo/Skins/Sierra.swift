import SwiftUI

// MARK: - Sierra
// Author: Bubo Team
// Golden hour in the Sierras — warm amber light pouring over terracotta
// mountains. Radial gradient simulates a warm sunset light source.
// Everything is bathed in warmth: the gradients, the fills, the separators.

extension SkinCatalog {
    static let sierra = SkinDefinition(
        id: "sierra",
        displayName: "Sierra",
        author: "Bubo",
        // Rich amber — deep golden hour warmth
        accentColor: Color(red: 0.85, green: 0.60, blue: 0.28),
        // Red desert earth surface
        surfaceTint: Color(red: 0.16, green: 0.09, blue: 0.03),
        surfaceTintOpacity: 0.25,
        // Radial from top-trailing — sunset light source
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.65, green: 0.38, blue: 0.14).opacity(0.18),
                Color(red: 0.40, green: 0.20, blue: 0.08).opacity(0.10),
                .clear,
            ],
            style: .radial(center: .topTrailing, startRadius: 0, endRadius: 450)
        ),
        previewColors: [
            Color(red: 0.85, green: 0.60, blue: 0.28),
            Color(red: 0.62, green: 0.35, blue: 0.18),
        ],
        prefersDarkTint: false,
        // Deep clay — amber→terracotta button shimmer
        secondaryAccent: Color(red: 0.72, green: 0.42, blue: 0.20),
        // Gradient — warm sunset energy
        buttonStyle: .gradient,
        // Terracotta toolbar — earthy complement
        toolbarTint: Color(red: 0.72, green: 0.45, blue: 0.30),
        // Warm earth bars — adobe wall feel
        barTint: Color(red: 0.48, green: 0.28, blue: 0.12),
        barTintOpacity: 0.12,
        platterTint: Color(red: 0.42, green: 0.24, blue: 0.10),
        platterTintOpacity: 0.06,
        // Rounded + semibold — warm and friendly, like a campfire chat
        fontDesign: .rounded,
        fontWeight: .semibold,
        headlineFontWeight: .bold,
        // Hierarchical — warm light gradients in icons
        sfSymbolRendering: .hierarchical,
        sfSymbolWeight: .medium,
        // Filled — warm saturated badges like sun-baked tiles
        badgeStyle: .filled,
        // Subtle — soft organic separators
        separatorStyle: .subtle,
        separatorOpacity: 0.35
    )
}
