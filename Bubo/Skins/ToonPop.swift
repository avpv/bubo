import SwiftUI

// MARK: - Toon Pop
// Author: Bubo Team
// Bold cartoon colors — inspired by Duffy Duck & Astro Boy Winamp skins.

extension SkinCatalog {
    static let toonPop = SkinDefinition(
        id: "toon_pop",
        displayName: "Toon Pop",
        author: "Bubo",
        accentColor: Color(red: 1.0, green: 0.3, blue: 0.3),
        surfaceTint: Color(red: 0.12, green: 0.05, blue: 0.0),
        surfaceTintOpacity: 0.35,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 1.0, green: 0.3, blue: 0.2).opacity(0.15),
                Color(red: 1.0, green: 0.8, blue: 0.0).opacity(0.10),
                .clear,
            ],
            style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
        ),
        previewColors: [
            Color(red: 1.0, green: 0.3, blue: 0.2),
            Color(red: 1.0, green: 0.8, blue: 0.0),
        ],
        prefersDarkTint: false
    )
}
