import SwiftUI

// MARK: - Sierra
// Author: Bubo Team
// Warm earth tones — inspired by California golden hills and macOS Sierra.
// Apple HIG: natural warmth, organic color grounding.

extension SkinCatalog {
    static let sierra = SkinDefinition(
        id: "sierra",
        displayName: "Sierra",
        author: "Bubo",
        accentColor: Color(red: 0.78, green: 0.56, blue: 0.32),
        surfaceTint: Color(red: 0.12, green: 0.08, blue: 0.04),
        surfaceTintOpacity: 0.16,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.58, green: 0.38, blue: 0.18).opacity(0.10),
                Color(red: 0.35, green: 0.22, blue: 0.12).opacity(0.06),
                .clear,
            ],
            style: .linear(startPoint: .topTrailing, endPoint: .bottomLeading)
        ),
        previewColors: [
            Color(red: 0.78, green: 0.56, blue: 0.32),
            Color(red: 0.52, green: 0.35, blue: 0.20),
        ],
        prefersDarkTint: false,
        secondaryAccent: Color(red: 0.65, green: 0.45, blue: 0.25),
        buttonStyle: .glass
    )
}
