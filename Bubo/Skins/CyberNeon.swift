import SwiftUI

// MARK: - Cyber Neon
// Author: Bubo Team
// Electric cyberpunk vibes — cyan and violet neon glow.

extension SkinCatalog {
    static let cyberNeon = SkinDefinition(
        id: "cyber_neon",
        displayName: "Cyber Neon",
        author: "Bubo",
        accentColor: Color(red: 0.0, green: 0.85, blue: 1.0),
        surfaceTint: Color(red: 0.0, green: 0.05, blue: 0.12),
        surfaceTintOpacity: 0.35,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.0, green: 0.4, blue: 0.6).opacity(0.22),
                Color(red: 0.3, green: 0.0, blue: 0.5).opacity(0.12),
                .clear,
            ],
            style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
        ),
        previewColors: [
            Color(red: 0.0, green: 0.8, blue: 1.0),
            Color(red: 0.5, green: 0.0, blue: 0.8),
        ],
        prefersDarkTint: true,
        secondaryAccent: Color(red: 0.4, green: 0.0, blue: 0.9),
        buttonStyle: .glass
    )
}
