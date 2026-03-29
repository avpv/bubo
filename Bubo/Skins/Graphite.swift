import SwiftUI

// MARK: - Graphite
// Author: Bubo Team
// Refined neutral gray — inspired by macOS Graphite appearance.
// Apple HIG: purposeful restraint, material-first design.

extension SkinCatalog {
    static let graphite = SkinDefinition(
        id: "graphite",
        displayName: "Graphite",
        author: "Bubo",
        accentColor: Color(red: 0.55, green: 0.55, blue: 0.60),
        surfaceTint: Color(red: 0.12, green: 0.12, blue: 0.14),
        surfaceTintOpacity: 0.15,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.35, green: 0.35, blue: 0.40).opacity(0.10),
                Color(red: 0.18, green: 0.18, blue: 0.22).opacity(0.06),
                .clear,
            ],
            style: .radial(center: .topLeading, startRadius: 0, endRadius: 500)
        ),
        previewColors: [
            Color(red: 0.50, green: 0.50, blue: 0.55),
            Color(red: 0.30, green: 0.30, blue: 0.35),
        ],
        prefersDarkTint: true,
        secondaryAccent: Color(red: 0.42, green: 0.42, blue: 0.48),
        buttonStyle: .glass
    )
}
