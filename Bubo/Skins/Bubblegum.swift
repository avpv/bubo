import SwiftUI

// MARK: - Bubblegum
// Author: Bubo Team
// Sweet pink-to-purple candy vibes.

extension SkinCatalog {
    static let bubblegum = SkinDefinition(
        id: "bubblegum",
        displayName: "Bubblegum",
        author: "Bubo",
        accentColor: Color(red: 1.0, green: 0.4, blue: 0.7),
        surfaceTint: Color(red: 0.12, green: 0.02, blue: 0.08),
        surfaceTintOpacity: 0.35,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 1.0, green: 0.3, blue: 0.6).opacity(0.18),
                Color(red: 0.7, green: 0.3, blue: 1.0).opacity(0.10),
                .clear,
            ],
            style: .linear(startPoint: .topTrailing, endPoint: .bottomLeading)
        ),
        previewColors: [
            Color(red: 1.0, green: 0.4, blue: 0.7),
            Color(red: 0.7, green: 0.3, blue: 1.0),
        ],
        prefersDarkTint: false
    )
}
