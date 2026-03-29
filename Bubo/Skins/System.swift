import SwiftUI

// MARK: - System
// Author: Bubo Team
// Pure macOS system appearance — no tinting, wallpaper shows through vibrancy.

extension SkinCatalog {
    static let system = SkinDefinition(
        id: "system",
        displayName: "System",
        author: "Bubo",
        accentColor: Color(red: 0.65, green: 0.58, blue: 0.50),
        surfaceTint: .clear,
        surfaceTintOpacity: 0,
        backgroundGradient: .clear,
        previewColors: [Color(red: 0.65, green: 0.58, blue: 0.50)],
        prefersDarkTint: false,
        buttonStyle: .gradient
    )
}
