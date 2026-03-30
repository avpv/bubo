import SwiftUI

// MARK: - Graphite
// Author: Bubo Team
// Swiss editorial design — inspired by macOS Graphite, Helvetica posters,
// and Dieter Rams' "less but better." Every element is deliberate.
// Monochrome palette forces hierarchy through weight and spacing alone.

extension SkinCatalog {
    static let graphite = SkinDefinition(
        id: "graphite",
        displayName: "Graphite",
        author: "Bubo",
        // Warm steel — slightly warmer than pure gray for depth
        accentColor: Color(red: 0.52, green: 0.52, blue: 0.58),
        // Charcoal surface — dark but not black
        surfaceTint: Color(red: 0.10, green: 0.10, blue: 0.12),
        surfaceTintOpacity: 0.22,
        // Very tight vertical gradient — editorial column feel
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.32, green: 0.32, blue: 0.38).opacity(0.10),
                Color(red: 0.15, green: 0.15, blue: 0.18).opacity(0.05),
            ],
            style: .linear(startPoint: .top, endPoint: .bottom)
        ),
        previewColors: [
            Color(red: 0.52, green: 0.52, blue: 0.58),
            Color(red: 0.25, green: 0.25, blue: 0.30),
        ],
        prefersDarkTint: true,
        secondaryAccent: Color(red: 0.42, green: 0.42, blue: 0.48),
        // Solid — no embellishment, Rams-like restraint
        buttonStyle: .solid,
        buttonShape: .roundedRect,
        // Taupe toolbar — warm counterpoint to cool steel
        toolbarTint: Color(red: 0.58, green: 0.54, blue: 0.48),
        // Heavy frosted chrome — editorial weight
        barMaterial: .ultraThick,
        barTint: Color(red: 0.32, green: 0.32, blue: 0.38),
        barTintOpacity: 0.10,
        platterTint: Color(red: 0.28, green: 0.28, blue: 0.32),
        platterTintOpacity: 0.06,
        // SF Pro — neutral, professional typeface
        fontDesign: .default,
        fontWeight: .medium,
        // Bold headlines — editorial contrast between head and body
        headlineFontWeight: .bold,
        // Monochrome — clean, no color noise in icons
        sfSymbolRendering: .monochrome,
        sfSymbolWeight: .regular,
        // Outlined — elegant editorial borders, like column rules
        badgeStyle: .outlined,
        // Subtle — thin hairline separators
        separatorStyle: .subtle,
        separatorOpacity: 0.25
    )
}
