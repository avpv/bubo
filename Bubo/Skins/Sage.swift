import SwiftUI

// MARK: - Sage
// Author: Bubo Team
// Natural muted green — calm, organic, inspired by Apple's environmental ethos.
// Apple HIG: biophilic color, reducing visual tension.

extension SkinCatalog {
    static let sage = SkinDefinition(
        id: "sage",
        displayName: "Sage",
        author: "Bubo",
        accentColor: Color(red: 0.42, green: 0.62, blue: 0.45),
        surfaceTint: Color(red: 0.05, green: 0.10, blue: 0.06),
        surfaceTintOpacity: 0.14,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.28, green: 0.48, blue: 0.30).opacity(0.09),
                Color(red: 0.15, green: 0.30, blue: 0.18).opacity(0.05),
                .clear,
            ],
            style: .radial(center: .topLeading, startRadius: 0, endRadius: 480)
        ),
        previewColors: [
            Color(red: 0.42, green: 0.62, blue: 0.45),
            Color(red: 0.30, green: 0.48, blue: 0.34),
        ],
        prefersDarkTint: false,
        secondaryAccent: Color(red: 0.35, green: 0.52, blue: 0.38),
        buttonStyle: .glass
    )
}
