import SwiftUI

// MARK: - Sunset Rider
// Author: Bubo Team
// Warm sunset gradients — golden hour vibes.

extension SkinCatalog {
    static let sunsetRider = SkinDefinition(
        id: "sunset_rider",
        displayName: "Sunset Rider",
        author: "Bubo",
        accentColor: Color(red: 1.0, green: 0.5, blue: 0.2),
        surfaceTint: Color(red: 0.12, green: 0.05, blue: 0.0),
        surfaceTintOpacity: 0.35,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 1.0, green: 0.4, blue: 0.1).opacity(0.20),
                Color(red: 0.8, green: 0.2, blue: 0.3).opacity(0.10),
                .clear,
            ],
            style: .radial(center: .top, startRadius: 0, endRadius: 450)
        ),
        previewColors: [
            Color(red: 1.0, green: 0.5, blue: 0.2),
            Color(red: 0.8, green: 0.2, blue: 0.3),
        ],
        prefersDarkTint: false,
        secondaryAccent: Color(red: 0.85, green: 0.25, blue: 0.3),
        buttonStyle: .gradient
    )
}
