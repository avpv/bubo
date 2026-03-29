import SwiftUI

// MARK: - Midnight
// Author: Bubo Team
// Deep navy-black — Apple Midnight hardware color brought to UI.
// Apple HIG: immersive dark experience with subtle depth.

extension SkinCatalog {
    static let midnight = SkinDefinition(
        id: "midnight",
        displayName: "Midnight",
        author: "Bubo",
        accentColor: Color(red: 0.35, green: 0.52, blue: 0.78),
        surfaceTint: Color(red: 0.02, green: 0.03, blue: 0.08),
        surfaceTintOpacity: 0.22,
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.12, green: 0.18, blue: 0.35).opacity(0.14),
                Color(red: 0.05, green: 0.08, blue: 0.18).opacity(0.08),
                .clear,
            ],
            style: .radial(center: .bottomLeading, startRadius: 0, endRadius: 520)
        ),
        previewColors: [
            Color(red: 0.25, green: 0.38, blue: 0.62),
            Color(red: 0.10, green: 0.14, blue: 0.28),
        ],
        prefersDarkTint: true,
        secondaryAccent: Color(red: 0.28, green: 0.42, blue: 0.65),
        buttonStyle: .glass
    )
}
