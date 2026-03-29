import SwiftUI

// MARK: - Arctic
// Author: Bubo Team
// Cool ice-blue — airy, bright, and spacious like fresh snowfall.
// Apple HIG: lightness and clarity, emphasizing content over chrome.

extension SkinCatalog {
    static let arctic = SkinDefinition(
        id: "arctic",
        displayName: "Arctic",
        author: "Bubo",
        accentColor: Color(red: 0.28, green: 0.63, blue: 0.82),
        surfaceTint: Color(red: 0.04, green: 0.08, blue: 0.12),
        surfaceTintOpacity: 0.12,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.22, green: 0.52, blue: 0.72).opacity(0.09),
                Color(red: 0.14, green: 0.32, blue: 0.48).opacity(0.05),
                .clear,
            ],
            style: .radial(center: .top, startRadius: 0, endRadius: 500)
        ),
        previewColors: [
            Color(red: 0.28, green: 0.63, blue: 0.82),
            Color(red: 0.55, green: 0.78, blue: 0.92),
        ],
        prefersDarkTint: false,
        secondaryAccent: Color(red: 0.38, green: 0.58, blue: 0.75),
        buttonStyle: .glass
    )
}
