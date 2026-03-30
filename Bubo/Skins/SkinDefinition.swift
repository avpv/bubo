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

// MARK: - Button Shape

/// Controls the clip/content shape used for primary and secondary buttons.
enum SkinButtonShape: String, Equatable, CaseIterable {
    /// Fully rounded ends — the default pill shape.
    case capsule
    /// Rounded rectangle with the standard corner radius.
    case roundedRect
    /// Sharp-cornered rectangle.
    case rectangle
}

// MARK: - Bar Material

/// Controls which SwiftUI `Material` is used for header/footer bars.
///
/// Maps 1:1 to Apple's `ShapeStyle` material variants. See Apple HIG
/// "Materials" for guidance on when to use each level.
enum SkinBarMaterial: String, Equatable, CaseIterable {
    /// Very subtle translucency — maximum content visibility.
    case ultraThin
    /// Light translucency.
    case thin
    /// Balanced translucency (system default for many controls).
    case regular
    /// Rich translucency — good default for bars.
    case thick
    /// Maximum translucency — most frosted/opaque.
    case ultraThick
    /// System bar material — adaptive, designed for toolbars and tab bars.
    case bar

    /// The corresponding SwiftUI `Material` value.
    var material: Material {
        switch self {
        case .ultraThin:  .ultraThinMaterial
        case .thin:       .thinMaterial
        case .regular:    .regularMaterial
        case .thick:      .thickMaterial
        case .ultraThick: .ultraThickMaterial
        case .bar:        .bar
        }
    }
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

    /// Shape used for button clipping and hit-testing.
    let buttonShape: SkinButtonShape

    /// Explicit foreground color for primary buttons.
    /// Overrides the automatic luminance-based contrast logic when set.
    let buttonColor: Color?

    /// Material used as the base layer for glass-style and secondary buttons.
    /// Defaults to `.regular` (DS.Materials.platter equivalent).
    let buttonMaterial: SkinBarMaterial

    /// Tint color for toolbar/utility buttons (Refresh, Settings, Quit).
    /// Apple HIG: secondary actions use a subtler, complementary color to
    /// establish visual hierarchy — primary action (Add) stays bold, toolbar
    /// buttons recede. Falls back to accent color if nil.
    let toolbarTint: Color?

    /// Material used for header and footer bars.
    /// Apple HIG: different material levels control translucency/vibrancy.
    /// Defaults to `.thick` for rich vibrancy.
    let barMaterial: SkinBarMaterial

    /// Optional color overlay on top of the bar material.
    /// Layered over the blur to give bars a custom tinted-glass look.
    let barTint: Color?

    /// Opacity of the bar tint overlay (0 = invisible, typically 0.05–0.25).
    let barTintOpacity: Double

    /// Material used for card/platter surfaces (form sections, event rows, pickers).
    /// Apple HIG: content surfaces should use a consistent material layer beneath bars.
    /// Defaults to `.regular`.
    let platterMaterial: SkinBarMaterial

    /// Optional color overlay on platter surfaces.
    let platterTint: Color?

    /// Opacity of the platter tint overlay (0 = invisible, typically 0.05–0.2).
    let platterTintOpacity: Double

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
        buttonStyle: SkinButtonStyle = .gradient,
        buttonShape: SkinButtonShape = .capsule,
        buttonColor: Color? = nil,
        buttonMaterial: SkinBarMaterial = .regular,
        toolbarTint: Color? = nil,
        barMaterial: SkinBarMaterial = .thick,
        barTint: Color? = nil,
        barTintOpacity: Double = 0,
        platterMaterial: SkinBarMaterial = .regular,
        platterTint: Color? = nil,
        platterTintOpacity: Double = 0
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
        self.buttonShape = buttonShape
        self.buttonColor = buttonColor
        self.buttonMaterial = buttonMaterial
        self.toolbarTint = toolbarTint
        self.barMaterial = barMaterial
        self.barTint = barTint
        self.barTintOpacity = barTintOpacity
        self.platterMaterial = platterMaterial
        self.platterTint = platterTint
        self.platterTintOpacity = platterTintOpacity
    }

    // MARK: - Derived

    /// Resolved secondary accent, falling back to a darkened version of accentColor.
    var resolvedSecondaryAccent: Color {
        secondaryAccent ?? accentColor.opacity(0.85)
    }

    /// Resolved toolbar tint, falling back to accent color at reduced opacity.
    /// Apple HIG: toolbar buttons should be visually subordinate to primary actions.
    var resolvedToolbarTint: Color {
        toolbarTint ?? accentColor.opacity(0.7)
    }

    /// Resolved SwiftUI `Material` for header/footer bars.
    var resolvedBarMaterial: Material {
        barMaterial.material
    }

    /// Resolved SwiftUI `Material` for button backgrounds (glass/secondary/destructive).
    var resolvedButtonMaterial: Material {
        buttonMaterial.material
    }

    /// Whether this skin has a custom bar tint overlay.
    var hasBarTint: Bool {
        barTint != nil && barTintOpacity > 0
    }

    /// Resolved SwiftUI `Material` for platter/card surfaces.
    var resolvedPlatterMaterial: Material {
        platterMaterial.material
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
        graphite,
        ocean,
        lavenderSkin,
        roseGold,
        midnight,
        sierra,
        arctic,
        sage,
        winXP,
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
