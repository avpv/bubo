import SwiftUI

// MARK: - Rose Gold
// Author: Bubo Team
// Luxury atelier — brushed copper and rose, like an Apple Watch Edition
// paired with a Hermès band. New York serif font elevates every label
// into something you'd see on a perfume box. Understated opulence.

extension SkinCatalog {
    static let roseGold = SkinDefinition(
        id: "rose_gold",
        displayName: "Rose Gold",
        author: "Bubo",
        // Warm copper-rose — richer, more jewelry-like
        accentColor: Color(red: 0.84, green: 0.50, blue: 0.46),
        // Warm shadow — brushed copper in low light
        surfaceTint: Color(red: 0.18, green: 0.07, blue: 0.05),
        surfaceTintOpacity: 0.22,
        // Diagonal warm gradient — luxury movement
        backgroundGradient: SkinGradient(
            colors: [
                Color(red: 0.78, green: 0.40, blue: 0.35).opacity(0.14),
                Color(red: 0.48, green: 0.22, blue: 0.20).opacity(0.08),
                .clear,
            ],
            style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
        ),
        previewColors: [
            Color(red: 0.84, green: 0.50, blue: 0.46),
            Color(red: 0.94, green: 0.68, blue: 0.58),
        ],
        prefersDarkTint: false,
        // Blush pink — copper→pink shimmer on buttons
        secondaryAccent: Color(red: 0.92, green: 0.62, blue: 0.54),
        // Gradient — jewel shimmer, polished surface
        buttonStyle: .gradient,
        // Gold toolbar — like gold paired with rose gold
        toolbarTint: Color(red: 0.78, green: 0.65, blue: 0.40),
        // Copper-tinted bars — brushed metal feel
        barTint: Color(red: 0.62, green: 0.38, blue: 0.30),
        barTintOpacity: 0.12,
        platterTint: Color(red: 0.58, green: 0.32, blue: 0.28),
        platterTintOpacity: 0.06,
        // New York serif — luxury, editorial, fashion-forward
        fontDesign: .serif,
        fontWeight: .medium,
        // Bold headlines — magazine cover energy
        headlineFontWeight: .bold,
        // Hierarchical — elegant depth in icons
        sfSymbolRendering: .hierarchical,
        sfSymbolWeight: .regular,
        // Outlined — thin elegant borders, like filigree
        badgeStyle: .outlined,
        // Accent — warm copper separator lines, decorative
        separatorStyle: .accent,
        separatorOpacity: 0.18
    )
}
