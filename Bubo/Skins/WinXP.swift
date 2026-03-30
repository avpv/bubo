import SwiftUI

// MARK: - Windows XP Luna
// Author: Bubo Team
// Pure nostalgia — the unmistakable bold blue taskbar, green Start button,
// and Bliss wallpaper sky. Bold type, multicolor icons, chunky separators.
// Everything is saturated, confident, and unapologetically colorful.

extension SkinCatalog {
    static let winXP = SkinDefinition(
        id: "win_xp",
        displayName: "XP Luna",
        author: "Bubo",
        // XP taskbar blue — iconic
        accentColor: Color(red: 0.0, green: 0.35, blue: 0.92),
        // Deep navy — dark taskbar base
        surfaceTint: Color(red: 0.02, green: 0.06, blue: 0.20),
        surfaceTintOpacity: 0.25,
        // Sky gradient — Bliss wallpaper horizon
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.16, green: 0.38, blue: 0.88).opacity(0.16),
                Color(red: 0.0, green: 0.22, blue: 0.58).opacity(0.10),
                .clear,
            ],
            style: .linear(startPoint: .top, endPoint: .bottom)
        ),
        previewColors: [
            Color(red: 0.0, green: 0.35, blue: 0.92),
            Color(red: 0.24, green: 0.62, blue: 0.20),
        ],
        prefersDarkTint: true,
        // Lighter XP blue for button gradient
        secondaryAccent: Color(red: 0.12, green: 0.48, blue: 0.98),
        // Gradient — bold Luna fills on buttons and title bars
        buttonStyle: .gradient,
        buttonShape: .roundedRect,
        buttonColor: .white,
        // XP Start button green — the iconic contrast
        toolbarTint: Color(red: 0.24, green: 0.62, blue: 0.20),
        // Ultra-thick bars — chunky XP taskbar weight
        barMaterial: .ultraThick,
        barTint: Color(red: 0.0, green: 0.24, blue: 0.68),
        barTintOpacity: 0.22,
        platterTint: Color(red: 0.10, green: 0.22, blue: 0.52),
        platterTintOpacity: 0.08,
        // SF Pro + bold — chunky, confident, Windows UI energy
        fontDesign: .default,
        fontWeight: .bold,
        headlineFontWeight: .bold,
        // Multicolor — XP loved saturated, colorful icons
        sfSymbolRendering: .multicolor,
        sfSymbolWeight: .bold,
        // Filled — bold saturated badges, primary-color confidence
        badgeStyle: .filled,
        // System — classic visible separators, thick and present
        separatorStyle: .system,
        separatorOpacity: 0.65
    )
}
