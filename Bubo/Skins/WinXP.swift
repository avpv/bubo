import SwiftUI

// MARK: - Windows XP Luna — Blue
// Author: Bubo Team
// The iconic default. Bold blue taskbar, green Start button, Bliss wallpaper
// sky. Everything is saturated, confident, and unapologetically colorful.
// This is the XP everyone remembers.

extension SkinCatalog {
    static let winXPBlue = SkinDefinition(
        id: "win_xp_blue",
        displayName: "XP Luna Blue",
        author: "Bubo",
        // XP taskbar blue — the iconic saturated blue
        accentColor: Color(red: 0.0, green: 0.33, blue: 0.84),
        // Deep navy — dark taskbar base
        surfaceTint: Color(red: 0.02, green: 0.06, blue: 0.20),
        surfaceTintOpacity: 0.25,
        // Sky gradient — Bliss wallpaper horizon glow
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.16, green: 0.38, blue: 0.88).opacity(0.16),
                Color(red: 0.0, green: 0.22, blue: 0.58).opacity(0.10),
                .clear,
            ],
            style: .linear(startPoint: .top, endPoint: .bottom)
        ),
        previewColors: [
            Color(red: 0.0, green: 0.33, blue: 0.84),
            Color(red: 0.22, green: 0.54, blue: 0.16),
        ],
        prefersDarkTint: true,
        // Lighter XP blue for button gradient highlight
        secondaryAccent: Color(red: 0.12, green: 0.48, blue: 0.98),
        buttonStyle: .gradient,
        buttonShape: .roundedRect,
        buttonColor: .white,
        // XP Start button green — the iconic taskbar contrast
        toolbarTint: Color(red: 0.22, green: 0.54, blue: 0.16),
        barMaterial: .ultraThick,
        barTint: Color(red: 0.0, green: 0.24, blue: 0.68),
        barTintOpacity: 0.22,
        platterTint: Color(red: 0.10, green: 0.22, blue: 0.52),
        platterTintOpacity: 0.08,
        fontDesign: .default,
        fontWeight: .bold,
        headlineFontWeight: .bold,
        sfSymbolRendering: .multicolor,
        sfSymbolWeight: .bold,
        badgeStyle: .filled,
        separatorStyle: .system,
        separatorOpacity: 0.65
    )
}

// MARK: - Windows XP Luna — Olive Green
// Author: Bubo Team
// The earthy alternative. Warm olive taskbar, golden-khaki title bars,
// muted sage greens. Feels like autumn in Redmond — grounded, warm,
// and unexpectedly sophisticated for 2001.

extension SkinCatalog {
    static let winXPOlive = SkinDefinition(
        id: "win_xp_olive",
        displayName: "XP Luna Olive",
        author: "Bubo",
        // Olive green — XP's warm earthy accent
        accentColor: Color(red: 0.46, green: 0.54, blue: 0.24),
        // Dark olive — deep forest floor base
        surfaceTint: Color(red: 0.08, green: 0.10, blue: 0.04),
        surfaceTintOpacity: 0.22,
        // Warm olive gradient — golden hour through leaves
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.50, green: 0.58, blue: 0.30).opacity(0.14),
                Color(red: 0.36, green: 0.42, blue: 0.18).opacity(0.08),
                .clear,
            ],
            style: .linear(startPoint: .top, endPoint: .bottom)
        ),
        previewColors: [
            Color(red: 0.46, green: 0.54, blue: 0.24),
            Color(red: 0.62, green: 0.66, blue: 0.42),
        ],
        prefersDarkTint: true,
        // Golden olive — lighter khaki for gradient highlight
        secondaryAccent: Color(red: 0.62, green: 0.66, blue: 0.42),
        buttonStyle: .gradient,
        buttonShape: .roundedRect,
        buttonColor: .white,
        // Dark olive — Start button in the olive scheme
        toolbarTint: Color(red: 0.36, green: 0.46, blue: 0.22),
        barMaterial: .ultraThick,
        barTint: Color(red: 0.36, green: 0.42, blue: 0.18),
        barTintOpacity: 0.20,
        platterTint: Color(red: 0.28, green: 0.32, blue: 0.14),
        platterTintOpacity: 0.07,
        fontDesign: .default,
        fontWeight: .bold,
        headlineFontWeight: .bold,
        sfSymbolRendering: .multicolor,
        sfSymbolWeight: .bold,
        badgeStyle: .filled,
        separatorStyle: .system,
        separatorOpacity: 0.65
    )
}

// MARK: - Windows XP Luna — Silver
// Author: Bubo Team
// The refined option. Cool steel-blue taskbar, brushed aluminum title bars,
// lavender undertones. Corporate XP — what IT departments picked when blue
// felt too playful. Quiet confidence, metallic polish.

extension SkinCatalog {
    static let winXPSilver = SkinDefinition(
        id: "win_xp_silver",
        displayName: "XP Luna Silver",
        author: "Bubo",
        // Steel blue-silver — XP Silver's cool metallic accent
        accentColor: Color(red: 0.46, green: 0.47, blue: 0.56),
        // Cool charcoal — subtle blue-gray undertone
        surfaceTint: Color(red: 0.08, green: 0.08, blue: 0.12),
        surfaceTintOpacity: 0.20,
        // Brushed steel gradient — cool metallic sheen
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.50, green: 0.51, blue: 0.60).opacity(0.12),
                Color(red: 0.38, green: 0.38, blue: 0.46).opacity(0.07),
                .clear,
            ],
            style: .linear(startPoint: .top, endPoint: .bottom)
        ),
        previewColors: [
            Color(red: 0.46, green: 0.47, blue: 0.56),
            Color(red: 0.66, green: 0.67, blue: 0.74),
        ],
        prefersDarkTint: true,
        // Lighter silver-blue — gradient highlight
        secondaryAccent: Color(red: 0.60, green: 0.61, blue: 0.70),
        buttonStyle: .gradient,
        buttonShape: .roundedRect,
        buttonColor: .white,
        // Deeper steel — Start button in the silver scheme
        toolbarTint: Color(red: 0.37, green: 0.38, blue: 0.50),
        barMaterial: .ultraThick,
        barTint: Color(red: 0.38, green: 0.38, blue: 0.50),
        barTintOpacity: 0.18,
        platterTint: Color(red: 0.30, green: 0.30, blue: 0.40),
        platterTintOpacity: 0.06,
        fontDesign: .default,
        fontWeight: .bold,
        headlineFontWeight: .bold,
        sfSymbolRendering: .multicolor,
        sfSymbolWeight: .bold,
        badgeStyle: .filled,
        separatorStyle: .system,
        separatorOpacity: 0.65
    )
}
