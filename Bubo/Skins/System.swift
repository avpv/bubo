import SwiftUI

// MARK: - System
// Author: Bubo Team
// Modern macOS — follows the user's system accent color with a polished,
// understated glass aesthetic. The "Apple default" feel: nothing shouts,
// everything just works.

extension SkinCatalog {
    static let system = SkinDefinition(
        id: "system",
        displayName: "System",
        author: "Bubo",
        accentColor: .accentColor,
        surfaceTint: Color.accentColor,
        surfaceTintOpacity: 0.08,
        backgroundGradient: SkinGradient(
            colors: [
                Color.accentColor.opacity(0.14),
                Color.accentColor.opacity(0.05),
                .clear,
            ],
            style: .radial(center: .topLeading, startRadius: 0, endRadius: 500)
        ),
        previewColors: [Color.accentColor.opacity(0.6), Color.accentColor.opacity(0.3)],
        prefersDarkTint: false,
        secondaryAccent: Color.accentColor.opacity(0.7),
        // Glass — clean, spatial, modern Apple
        buttonStyle: .glass,
        toolbarTint: Color.accentColor.opacity(0.55),
        // Standard thick bars — polished chrome
        barMaterial: .thick,
        barTint: Color.accentColor,
        barTintOpacity: 0.04,
        // Typography: rounded, medium — approachable but not heavy
        fontDesign: .rounded,
        fontWeight: .medium,
        headlineFontWeight: .semibold,
        sfSymbolRendering: .hierarchical,
        sfSymbolWeight: .medium,
        badgeStyle: .tinted,
        separatorStyle: .subtle,
        separatorOpacity: 0.35
    )
}
