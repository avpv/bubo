import SwiftUI

// MARK: - Ocean
// Author: Bubo Team
// Apple's signature blue refined — deep, confident, system-native feel.
// Apple HIG: clarity through color, functional elegance.

extension SkinCatalog {
    static let ocean = SkinDefinition(
        id: "ocean",
        displayName: "Ocean",
        author: "Bubo",
        accentColor: Color(red: 0.0, green: 0.48, blue: 1.0),
        surfaceTint: Color(red: 0.02, green: 0.06, blue: 0.16),
        surfaceTintOpacity: 0.18,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.0, green: 0.35, blue: 0.75).opacity(0.12),
                Color(red: 0.04, green: 0.12, blue: 0.35).opacity(0.07),
                .clear,
            ],
            style: .radial(center: .topTrailing, startRadius: 0, endRadius: 500)
        ),
        previewColors: [
            Color(red: 0.0, green: 0.48, blue: 1.0),
            Color(red: 0.10, green: 0.22, blue: 0.52),
        ],
        prefersDarkTint: true,
        secondaryAccent: Color(red: 0.15, green: 0.38, blue: 0.80),
        buttonStyle: .glass
    )
}
