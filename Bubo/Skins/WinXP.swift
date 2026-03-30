import SwiftUI

// MARK: - Windows XP Luna
// Author: Bubo Team
// Nostalgic tribute to the Windows XP Luna theme — bold blue taskbar,
// green Start button energy, and that unmistakable Bliss gradient sky.

extension SkinCatalog {
    static let winXP = SkinDefinition(
        id: "win_xp",
        displayName: "XP Luna",
        author: "Bubo",

        // XP taskbar / title bar blue
        accentColor: Color(red: 0.0, green: 0.33, blue: 0.89),

        // Deep navy surface mood — mimics XP's dark taskbar base
        surfaceTint: Color(red: 0.02, green: 0.05, blue: 0.18),
        surfaceTintOpacity: 0.22,

        // Sky-blue gradient reminiscent of XP's Bliss wallpaper horizon
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.14, green: 0.36, blue: 0.86).opacity(0.14),
                Color(red: 0.0, green: 0.20, blue: 0.55).opacity(0.08),
                .clear,
            ],
            style: .linear(startPoint: .top, endPoint: .bottom)
        ),

        previewColors: [
            Color(red: 0.0, green: 0.33, blue: 0.89),
            Color(red: 0.22, green: 0.60, blue: 0.18),
        ],
        prefersDarkTint: true,

        // Lighter XP blue for button gradient
        secondaryAccent: Color(red: 0.10, green: 0.45, blue: 0.95),

        // XP used bold gradient fills on buttons and title bars
        buttonStyle: .gradient,
        // XP buttons were rounded rectangles — classic Win32 controls
        buttonShape: .roundedRect,
        // White button text — XP's high-contrast button labels
        buttonColor: .white,

        // XP Start button green for toolbar — the iconic contrast
        toolbarTint: Color(red: 0.22, green: 0.60, blue: 0.18),
        // Thick opaque bars — XP's chunky title bars and taskbar
        barMaterial: .ultraThick,
        // Bold blue bar tint — iconic Luna taskbar color
        barTint: Color(red: 0.0, green: 0.22, blue: 0.65),
        barTintOpacity: 0.20,
        // Light blue platters — XP window body feel
        platterTint: Color(red: 0.08, green: 0.20, blue: 0.50),
        platterTintOpacity: 0.06,
        fontDesign: .default,
        fontWeight: .bold,
        headlineFontWeight: .bold,
        sfSymbolRendering: .multicolor,
        sfSymbolWeight: .bold,
        badgeStyle: .filled,
        separatorStyle: .system,
        separatorOpacity: 0.6
    )
}
