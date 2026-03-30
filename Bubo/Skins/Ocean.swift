import SwiftUI

// MARK: - Ocean
// Author: Bubo Team
// Deep bioluminescent ocean — bold cobalt blues with aqua highlights,
// like diving into a kelp forest at twilight. Strong tinting creates
// a fully immersive underwater atmosphere.

extension SkinCatalog {
    static let ocean = SkinDefinition(
        id: "ocean",
        displayName: "Ocean",
        author: "Bubo",
        // Vivid cobalt — electric, deep
        accentColor: Color(red: 0.0, green: 0.44, blue: 0.98),
        // Deep abyss surface tint
        surfaceTint: Color(red: 0.01, green: 0.05, blue: 0.16),
        surfaceTintOpacity: 0.30,
        // Strong diagonal — light filtering through surface waves
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.0, green: 0.35, blue: 0.75).opacity(0.22),
                Color(red: 0.02, green: 0.10, blue: 0.35).opacity(0.12),
                .clear,
            ],
            style: .linear(startPoint: .topTrailing, endPoint: .bottomLeading)
        ),
        previewColors: [
            Color(red: 0.0, green: 0.44, blue: 0.98),
            Color(red: 0.05, green: 0.20, blue: 0.52),
        ],
        prefersDarkTint: true,
        // Sky blue — surface light breaking through
        secondaryAccent: Color(red: 0.18, green: 0.58, blue: 1.0),
        // Gradient — vivid, energetic like bioluminescence
        buttonStyle: .gradient,
        // Aqua/cyan toolbar — sunlight on water surface
        toolbarTint: Color(red: 0.0, green: 0.72, blue: 0.75),
        // Regular bars — let the ocean gradient show through
        barMaterial: .regular,
        barTint: Color(red: 0.0, green: 0.18, blue: 0.45),
        barTintOpacity: 0.18,
        platterTint: Color(red: 0.0, green: 0.12, blue: 0.35),
        platterTintOpacity: 0.10,
        // Rounded + semibold — friendly but bold, like ocean waves
        fontDesign: .rounded,
        fontWeight: .semibold,
        headlineFontWeight: .bold,
        // Hierarchical — depth layers like underwater light
        sfSymbolRendering: .hierarchical,
        sfSymbolWeight: .semibold,
        // Filled — bold, saturated, like fish scales catching light
        badgeStyle: .filled,
        // Accent — cobalt blue separator lines, ocean current
        separatorStyle: .accent,
        separatorOpacity: 0.2
    )
}
