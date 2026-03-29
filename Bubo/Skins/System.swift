import SwiftUI

// MARK: - System
// Author: Bubo Team
// Pure macOS system appearance — no tinting, wallpaper shows through vibrancy.

extension SkinCatalog {
    static let system = SkinDefinition(
        id: "system",
        displayName: "System",
        author: "Bubo",
        accentColor: .accentColor,
        surfaceTint: .clear,
        surfaceTintOpacity: 0,
        backgroundGradient: .clear,
        previewColors: [Color(white: 0.5)],
        prefersDarkTint: false,
        buttonStyle: .gradient
    )
}
