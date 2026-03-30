import SwiftUI

// MARK: - Classic (Default)
// Author: Bubo Team
// Pure vanilla macOS — zero decoration, zero opinion.
// For users who want Bubo to disappear into the OS.

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
        buttonStyle: .solid,
        // SF Pro, regular weight — pure system appearance
        fontDesign: .default,
        fontWeight: .regular,
        headlineFontWeight: .medium,
        sfSymbolRendering: .monochrome,
        sfSymbolWeight: .regular,
        badgeStyle: .tinted,
        separatorStyle: .system
    )
}
