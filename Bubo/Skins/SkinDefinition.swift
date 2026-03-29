import SwiftUI

// MARK: - Button Style

/// Controls how primary buttons render within a skin.
enum SkinButtonStyle: Equatable {
    /// Solid fill using accent color.
    case solid
    /// Subtle gradient from accentColor → secondaryAccent.
    case gradient
    /// Glass / frosted appearance with accent tint.
    case glass
}

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

    /// Optional secondary accent (e.g. for gradients on buttons). Falls back to accentColor darkened.
    let secondaryAccent: Color?

    /// Button fill style — controls primary button appearance.
    let buttonStyle: SkinButtonStyle

    init(
        id: String,
        displayName: String,
        author: String,
        accentColor: Color,
        surfaceTint: Color,
        surfaceTintOpacity: Double,
        backgroundGradient: SkinGradient,
        previewColors: [Color],
        prefersDarkTint: Bool,
        secondaryAccent: Color? = nil,
        buttonStyle: SkinButtonStyle = .gradient
    ) {
        self.id = id
        self.displayName = displayName
        self.author = author
        self.accentColor = accentColor
        self.surfaceTint = surfaceTint
        self.surfaceTintOpacity = surfaceTintOpacity
        self.backgroundGradient = backgroundGradient
        self.previewColors = previewColors
        self.prefersDarkTint = prefersDarkTint
        self.secondaryAccent = secondaryAccent
        self.buttonStyle = buttonStyle
    }

    // MARK: - Derived

    /// Resolved secondary accent, falling back to a darkened version of accentColor.
    var resolvedSecondaryAccent: Color {
        secondaryAccent ?? accentColor.opacity(0.85)
    }

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
    var isClassic: Bool { id == "classic" }

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
///
/// Users can also create custom `.buboskin` files (JSON) and import them
/// via Settings — no code changes needed. See `CustomSkinLoader` for details.
enum SkinCatalog {
    /// All built-in skins. Order here = order in the picker.
    static let builtInSkins: [SkinDefinition] = [
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

    /// All skins including user-imported custom skins.
    static var allSkins: [SkinDefinition] {
        builtInSkins + CustomSkinLoader.shared.customSkins
    }

    /// Look up a skin by its ID. Falls back to Classic if not found.
    static func skin(forID id: String) -> SkinDefinition {
        allSkins.first { $0.id == id } ?? classic
    }

    /// The default skin.
    static let defaultSkin = system
}
