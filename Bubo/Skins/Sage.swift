import SwiftUI

// MARK: - Sage
// Author: Bubo Team
// Forest journal — natural greens, organic textures, grounded calm.
// New York serif font gives it the feel of a hand-bound field journal.
// Solid buttons like river stones. Everything is unhurried and warm.

extension SkinCatalog {
    static let sage = SkinDefinition(
        id: "sage",
        displayName: "Sage",
        author: "Bubo",
        // Deep forest green — saturated, earthy
        accentColor: Color(red: 0.34, green: 0.60, blue: 0.40),
        // Dark moss — forest floor
        surfaceTint: Color(red: 0.05, green: 0.12, blue: 0.06),
        surfaceTintOpacity: 0.20,
        // Radial from bottom-leading — light through canopy
        backgroundGradient: SkinGradient(
            colors: [
                .clear,
                Color(red: 0.20, green: 0.38, blue: 0.22).opacity(0.08),
                Color(red: 0.24, green: 0.45, blue: 0.28).opacity(0.12),
            ],
            style: .radial(center: .bottomLeading, startRadius: 0, endRadius: 450)
        ),
        previewColors: [
            Color(red: 0.34, green: 0.60, blue: 0.40),
            Color(red: 0.24, green: 0.40, blue: 0.28),
        ],
        prefersDarkTint: true,
        secondaryAccent: Color(red: 0.30, green: 0.50, blue: 0.34),
        // Solid — grounded, organic, no decoration
        buttonStyle: .solid,
        // Rounded rect — river stone shape
        buttonShape: .roundedRect,
        // Warm bark brown toolbar — natural earth complement
        toolbarTint: Color(red: 0.60, green: 0.50, blue: 0.38),
        // Moss-tinted bars — canopy overhead
        barTint: Color(red: 0.18, green: 0.30, blue: 0.18),
        barTintOpacity: 0.10,
        platterTint: Color(red: 0.14, green: 0.26, blue: 0.16),
        platterTintOpacity: 0.06,
        // New York serif — bookish, field journal, literary
        fontDesign: .serif,
        fontWeight: .regular,
        headlineFontWeight: .semibold,
        // Monochrome — simple, organic, no visual noise
        sfSymbolRendering: .monochrome,
        sfSymbolWeight: .regular,
        // Tinted — soft natural badge fills
        badgeStyle: .tinted,
        // System — traditional separators, like ruled notebook lines
        separatorStyle: .system,
        separatorOpacity: 0.4
    )
}
