import SwiftUI

// MARK: - Classic (Default)
// Author: Bubo Team
// The default system appearance — no custom tinting.

extension SkinCatalog {
    static let classic = SkinDefinition(
        id: "classic",
        displayName: "Classic",
        author: "Bubo",
        accentColor: .accentColor,
        surfaceTint: .clear,
        surfaceTintOpacity: 0,
        backgroundGradient: .clear,
        previewColors: [.gray],
        prefersDarkTint: false,
        buttonStyle: .solid
    )
}
