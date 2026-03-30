import SwiftUI

// MARK: - Sage
// Author: Bubo Team
// Natural forest green — calm, organic, grounded.
// Apple HIG: biophilic color, reducing visual tension.
// Personality: zen, organic. Solid buttons for a grounded,
// no-frills feel — like a well-worn leather journal.

extension SkinCatalog {
    static let sage = SkinDefinition(
        id: "sage",
        displayName: "Sage",
        author: "Bubo",
        // Deeper forest green — more saturated, more character
        accentColor: Color(red: 0.32, green: 0.58, blue: 0.38),
        // Dark moss surface — forest floor
        surfaceTint: Color(red: 0.04, green: 0.10, blue: 0.05),
        surfaceTintOpacity: 0.18,
        // Radial from bottom-leading — like light filtering through canopy
        backgroundGradient: SkinGradient(
            colors: [
                .clear,
                Color(red: 0.18, green: 0.35, blue: 0.20).opacity(0.06),
                Color(red: 0.22, green: 0.42, blue: 0.25).opacity(0.10),
            ],
            style: .radial(center: .bottomLeading, startRadius: 0, endRadius: 450)
        ),
        previewColors: [
            Color(red: 0.32, green: 0.58, blue: 0.38),
            Color(red: 0.22, green: 0.38, blue: 0.25),
        ],
        prefersDarkTint: true,
        secondaryAccent: Color(red: 0.28, green: 0.48, blue: 0.32),
        // HIG: solid — grounded, organic, simple
        buttonStyle: .solid,
        // Rounded rect — organic, natural, like a river stone
        buttonShape: .roundedRect,
        // Warm brown toolbar — like tree bark, earth complement to green
        toolbarTint: Color(red: 0.58, green: 0.48, blue: 0.35),
        // Moss-tinted bars — forest canopy overhead
        barTint: Color(red: 0.15, green: 0.28, blue: 0.16),
        barTintOpacity: 0.08,
        // Green platters — dappled forest floor
        platterTint: Color(red: 0.12, green: 0.24, blue: 0.14),
        platterTintOpacity: 0.05,
        fontDesign: .serif,
        fontWeight: .regular,
        headlineFontWeight: .semibold,
        sfSymbolRendering: .monochrome,
        sfSymbolWeight: .regular,
        badgeStyle: .tinted,
        separatorStyle: .system,
        separatorOpacity: 0.4
    )
}
