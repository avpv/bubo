import SwiftUI

// MARK: - Slim Dark
// Author: Bubo Team
// Moody purple haze — inspired by slimshdy.wsz Winamp skin.

extension SkinCatalog {
    static let slimDark = SkinDefinition(
        id: "slim_dark",
        displayName: "Slim Dark",
        author: "Bubo",
        accentColor: Color(red: 0.65, green: 0.5, blue: 0.9),
        surfaceTint: Color(red: 0.08, green: 0.04, blue: 0.15),
        surfaceTintOpacity: 0.35,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.3, green: 0.15, blue: 0.5).opacity(0.25),
                Color(red: 0.15, green: 0.1, blue: 0.25).opacity(0.15),
                .clear,
            ],
            style: .radial(center: .bottomLeading, startRadius: 0, endRadius: 500)
        ),
        previewColors: [
            Color(red: 0.3, green: 0.15, blue: 0.5),
            Color(red: 0.5, green: 0.3, blue: 0.7),
        ],
        prefersDarkTint: true
    )
}
