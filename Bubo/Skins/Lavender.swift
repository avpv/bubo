import SwiftUI

// MARK: - Lavender
// Author: Bubo Team
// Soft violet mist — inspired by iOS/macOS purple system accents.
// Apple HIG: gentle, approachable color that supports focus.

extension SkinCatalog {
    static let lavenderSkin = SkinDefinition(
        id: "lavender",
        displayName: "Lavender",
        author: "Bubo",
        accentColor: Color(red: 0.58, green: 0.44, blue: 0.86),
        surfaceTint: Color(red: 0.08, green: 0.05, blue: 0.14),
        surfaceTintOpacity: 0.16,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.42, green: 0.30, blue: 0.68).opacity(0.11),
                Color(red: 0.22, green: 0.16, blue: 0.42).opacity(0.06),
                .clear,
            ],
            style: .radial(center: .top, startRadius: 0, endRadius: 480)
        ),
        previewColors: [
            Color(red: 0.58, green: 0.44, blue: 0.86),
            Color(red: 0.35, green: 0.25, blue: 0.58),
        ],
        prefersDarkTint: false,
        secondaryAccent: Color(red: 0.45, green: 0.32, blue: 0.72),
        buttonStyle: .glass
    )
}
