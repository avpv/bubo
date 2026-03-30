import SwiftUI

// MARK: - Rose Gold
// Author: Bubo Team
// Warm pink-copper — inspired by Apple hardware finishes.
// Apple HIG: warmth and approachability through refined material tones.

extension SkinCatalog {
    static let roseGold = SkinDefinition(
        id: "rose_gold",
        displayName: "Rose Gold",
        author: "Bubo",
        accentColor: Color(red: 0.84, green: 0.54, blue: 0.50),
        surfaceTint: Color(red: 0.14, green: 0.06, blue: 0.05),
        surfaceTintOpacity: 0.16,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.72, green: 0.42, blue: 0.38).opacity(0.10),
                Color(red: 0.48, green: 0.28, blue: 0.26).opacity(0.06),
                .clear,
            ],
            style: .radial(center: .topTrailing, startRadius: 0, endRadius: 480)
        ),
        previewColors: [
            Color(red: 0.84, green: 0.54, blue: 0.50),
            Color(red: 0.62, green: 0.38, blue: 0.35),
        ],
        prefersDarkTint: false,
        secondaryAccent: Color(red: 0.72, green: 0.44, blue: 0.40),
        buttonStyle: .glass,
        // HIG: warm amber complement to rose-copper accent
        toolbarTint: Color(red: 0.78, green: 0.62, blue: 0.42)
    )
}
