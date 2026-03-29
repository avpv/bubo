import SwiftUI

// MARK: - Palm Beach
// Author: Bubo Team
// Tropical warmth — coral and golden pastels inspired by PALMAMP.

extension SkinCatalog {
    static let palmBeach = SkinDefinition(
        id: "palm_beach",
        displayName: "Palm Beach",
        author: "Bubo",
        accentColor: Color(red: 1.0, green: 0.55, blue: 0.35),
        surfaceTint: Color(red: 0.15, green: 0.08, blue: 0.02),
        surfaceTintOpacity: 0.35,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 1.0, green: 0.55, blue: 0.35).opacity(0.18),
                Color(red: 0.95, green: 0.8, blue: 0.3).opacity(0.10),
                .clear,
            ],
            style: .radial(center: .topTrailing, startRadius: 0, endRadius: 500)
        ),
        previewColors: [
            Color(red: 1.0, green: 0.55, blue: 0.35),
            Color(red: 0.95, green: 0.8, blue: 0.3),
        ],
        prefersDarkTint: false,
        secondaryAccent: Color(red: 0.95, green: 0.75, blue: 0.25),
        buttonStyle: .gradient
    )
}
