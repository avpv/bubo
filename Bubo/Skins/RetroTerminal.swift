import SwiftUI

// MARK: - Retro Terminal
// Author: Bubo Team
// Green phosphor on dark — classic terminal / Matrix aesthetic.

extension SkinCatalog {
    static let retroTerminal = SkinDefinition(
        id: "retro_terminal",
        displayName: "Retro Terminal",
        author: "Bubo",
        accentColor: Color(red: 0.0, green: 1.0, blue: 0.4),
        surfaceTint: Color(red: 0.0, green: 0.08, blue: 0.02),
        surfaceTintOpacity: 0.35,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.0, green: 0.3, blue: 0.1).opacity(0.25),
                Color(red: 0.0, green: 0.15, blue: 0.05).opacity(0.15),
                .clear,
            ],
            style: .linear(startPoint: .top, endPoint: .bottom)
        ),
        previewColors: [
            Color(red: 0.0, green: 0.8, blue: 0.3),
            Color(red: 0.05, green: 0.15, blue: 0.05),
        ],
        prefersDarkTint: true
    )
}
