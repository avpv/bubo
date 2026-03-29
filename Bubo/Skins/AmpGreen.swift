import SwiftUI

// MARK: - Amp Green
// Author: Bubo Team
// Inspired by the iconic Winamp classic skin — neon green on dark.

extension SkinCatalog {
    static let ampGreen = SkinDefinition(
        id: "amp_green",
        displayName: "Amp Green",
        author: "Bubo",
        accentColor: Color(red: 0.0, green: 0.9, blue: 0.0),
        surfaceTint: Color(red: 0.0, green: 0.15, blue: 0.0),
        surfaceTintOpacity: 0.35,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.0, green: 0.18, blue: 0.0).opacity(0.5),
                Color(red: 0.0, green: 0.08, blue: 0.0).opacity(0.3),
                .clear,
            ],
            style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
        ),
        previewColors: [
            Color(red: 0.0, green: 0.7, blue: 0.0),
            Color(red: 0.1, green: 0.2, blue: 0.1),
        ],
        prefersDarkTint: true
    )
}
