import SwiftUI

// MARK: - Ocean
// Author: Bubo Team
// Deep vivid blue — bold confidence, ocean depth.
// Apple HIG: clarity through color, functional elegance.
// Personality: energetic, bold. Gradient buttons for vibrancy,
// strong tinting for an immersive "underwater" atmosphere.

extension SkinCatalog {
    static let ocean = SkinDefinition(
        id: "ocean",
        displayName: "Ocean",
        author: "Bubo",
        // Vivid cobalt blue — bolder than system blue
        accentColor: Color(red: 0.0, green: 0.42, blue: 0.95),
        // Deep ocean surface
        surfaceTint: Color(red: 0.01, green: 0.04, blue: 0.14),
        surfaceTintOpacity: 0.25,
        // Strong diagonal gradient — sense of depth and movement
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.0, green: 0.30, blue: 0.70).opacity(0.18),
                Color(red: 0.02, green: 0.08, blue: 0.30).opacity(0.10),
                .clear,
            ],
            style: .linear(startPoint: .topTrailing, endPoint: .bottomLeading)
        ),
        previewColors: [
            Color(red: 0.0, green: 0.42, blue: 0.95),
            Color(red: 0.05, green: 0.18, blue: 0.48),
        ],
        prefersDarkTint: true,
        // Lighter sky blue for button gradient — surface-to-depth feel
        secondaryAccent: Color(red: 0.15, green: 0.55, blue: 1.0),
        // HIG: gradient buttons — vivid, energetic primary actions
        buttonStyle: .gradient,
        // Aqua/cyan toolbar — like sunlight hitting water surface
        toolbarTint: Color(red: 0.0, green: 0.68, blue: 0.72)
    )
}
