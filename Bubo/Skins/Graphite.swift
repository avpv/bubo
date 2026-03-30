import SwiftUI

// MARK: - Graphite
// Author: Bubo Team
// Professional monochrome — inspired by macOS Graphite appearance.
// Apple HIG: purposeful restraint, material-first design.
// Personality: no-nonsense, clean, editorial. Solid buttons for
// a utilitarian feel — form follows function.

extension SkinCatalog {
    static let graphite = SkinDefinition(
        id: "graphite",
        displayName: "Graphite",
        author: "Bubo",
        // Cool steel gray — neutral, professional
        accentColor: Color(red: 0.50, green: 0.50, blue: 0.56),
        // Very dark charcoal surface
        surfaceTint: Color(red: 0.10, green: 0.10, blue: 0.12),
        surfaceTintOpacity: 0.20,
        // Tight linear gradient — clean editorial feel, not ambient glow
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.30, green: 0.30, blue: 0.36).opacity(0.08),
                Color(red: 0.15, green: 0.15, blue: 0.18).opacity(0.04),
            ],
            style: .linear(startPoint: .top, endPoint: .bottom)
        ),
        previewColors: [
            Color(red: 0.50, green: 0.50, blue: 0.56),
            Color(red: 0.25, green: 0.25, blue: 0.30),
        ],
        prefersDarkTint: true,
        secondaryAccent: Color(red: 0.40, green: 0.40, blue: 0.46),
        // HIG: solid buttons — utilitarian, no decoration
        buttonStyle: .solid,
        // Warm taupe toolbar — temperature contrast against cool gray
        toolbarTint: Color(red: 0.55, green: 0.52, blue: 0.48)
    )
}
