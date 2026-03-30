import SwiftUI

// MARK: - System
// Author: Bubo Team
// Modern macOS appearance — subtle accent glow, glass buttons, light tinting.

extension SkinCatalog {
    static let system = SkinDefinition(
        id: "system",
        displayName: "System",
        author: "Bubo",
        accentColor: .accentColor,
        surfaceTint: Color.accentColor,
        surfaceTintOpacity: 0.06,
        backgroundGradient: SkinGradient(
            colors: [
                Color.accentColor.opacity(0.12),
                Color.accentColor.opacity(0.04),
                .clear,
            ],
            style: .radial(center: .topLeading, startRadius: 0, endRadius: 500)
        ),
        previewColors: [Color.accentColor.opacity(0.6), Color.accentColor.opacity(0.3)],
        prefersDarkTint: false,
        secondaryAccent: Color.accentColor.opacity(0.7),
        buttonStyle: .glass,
        toolbarTint: Color.accentColor.opacity(0.55),
        fontDesign: .rounded,
        fontWeight: .medium,
        headlineFontWeight: .semibold,
        sfSymbolRendering: .hierarchical,
        sfSymbolWeight: .medium,
        badgeStyle: .tinted,
        separatorStyle: .subtle,
        separatorOpacity: 0.4
    )
}
