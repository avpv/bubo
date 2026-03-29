import SwiftUI

// MARK: - Skin Definition

/// A complete visual theme for Bubo.
///
/// To create a new skin, add a new Swift file in `Bubo/Skins/` and register
/// it in `SkinCatalog.allSkins`. See `TEMPLATE.swift` for a starting point
/// and `CONTRIBUTING_SKINS.md` in the repo root for full instructions.
struct SkinDefinition: Identifiable, Equatable {
    /// Unique identifier — used for persistence. Must be stable across versions.
    let id: String

    /// Display name shown in the skin picker.
    let displayName: String

    /// Author name / GitHub handle.
    let author: String

    /// Primary accent color used for buttons, highlights, and tint.
    let accentColor: Color

    /// Subtle color overlaid on surfaces to set the skin's mood.
    let surfaceTint: Color

    /// Opacity of the surface tint overlay (0 = none, typically 0.2–0.4).
    let surfaceTintOpacity: Double

    /// Background gradient specification.
    let backgroundGradient: SkinGradient

    /// 1–2 colors used for the skin picker thumbnail.
    let previewColors: [Color]

    /// Whether this skin has a dark-tinted mood (affects blend modes).
    let prefersDarkTint: Bool

    // MARK: - Derived

    var previewGradient: AnyShapeStyle {
        let colors = previewColors
        if colors.count <= 1 {
            return AnyShapeStyle(colors.first ?? .gray)
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    var accentBarGlow: Color {
        accentColor.opacity(0.4)
    }

    /// Whether this skin uses no custom tinting (system-native appearance).
    var isClassic: Bool { id == "classic" || id == "system" }

    static func == (lhs: SkinDefinition, rhs: SkinDefinition) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Gradient Specification

struct SkinGradient: Equatable {
    let colors: [Color]
    let style: Style

    enum Style: Equatable {
        case linear(startPoint: UnitPoint, endPoint: UnitPoint)
        case radial(center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat)
    }

    /// Empty gradient (transparent).
    static let clear = SkinGradient(colors: [], style: .linear(startPoint: .top, endPoint: .bottom))
}

// MARK: - Skin Catalog

/// Central registry of all available skins.
///
/// **To add a new skin:**
/// 1. Create a new file in `Bubo/Skins/` (copy `TEMPLATE.swift`)
/// 2. Define your skin as a `static let` on `SkinCatalog`
/// 3. Add it to the `allSkins` array below
///
/// That's it — your skin will appear in Settings automatically.
enum SkinCatalog {
    /// All registered skins. Order here = order in the picker.
    static let allSkins: [SkinDefinition] = [
        system,
        classic,
        ampGreen,
        palmBeach,
        toonPop,
        slimDark,
        cyberNeon,
        sunsetRider,
        retroTerminal,
        bubblegum,
    ]

    /// Look up a skin by its ID. Falls back to Classic if not found.
    static func skin(forID id: String) -> SkinDefinition {
        allSkins.first { $0.id == id } ?? classic
    }

    /// The default skin.
    static let defaultSkin = system
}
