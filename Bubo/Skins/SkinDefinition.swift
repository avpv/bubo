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

// MARK: - Animation Style

/// Controls the physics and feeling of micro-interactions within the skin.
enum SkinAnimationStyle: String, Equatable, CaseIterable, Codable {
    case bouncy
    case smooth
    case snappy

    var swiftUIAnimation: Animation {
        switch self {
        case .bouncy: return .spring(duration: 0.35, bounce: 0.4)
        case .smooth: return .spring(duration: 0.4, bounce: 0.2)
        case .snappy: return .spring(duration: 0.25, bounce: 0.1)
        }
    }
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

// MARK: - Font Design

/// Controls which system font design is used throughout the skin.
/// Apple HIG 2026 §Typography: "Never substitute the system font with a custom
/// typeface in utility-class windows." Only SF Pro and SF Rounded are appropriate
/// for interface elements; serif and monospaced designs are excluded.
enum SkinFontDesign: String, Equatable, CaseIterable, Codable {
    case `default`
    case rounded

    var swiftUIDesign: Font.Design {
        switch self {
        case .default:     .default
        case .rounded:     .rounded
        }
    }
}

// MARK: - Font Weight

/// Allowed font weights for skins. Excludes ultraLight/thin per HIG legibility rules.
enum SkinFontWeight: String, Equatable, CaseIterable, Codable {
    case regular
    case medium
    case semibold
    case bold

    var swiftUIWeight: Font.Weight {
        switch self {
        case .regular:  .regular
        case .medium:   .medium
        case .semibold: .semibold
        case .bold:     .bold
        }
    }
}

// MARK: - SF Symbol Rendering

/// Controls how SF Symbols are rendered within a skin.
/// Apple HIG 2026 §Symbols: prefers hierarchical for utility apps.
enum SkinSymbolRendering: String, Equatable, CaseIterable, Codable {
    case monochrome
    case hierarchical
    case palette
    case multicolor

    var swiftUIMode: SymbolRenderingMode {
        switch self {
        case .monochrome:   .monochrome
        case .hierarchical: .hierarchical
        case .palette:      .palette
        case .multicolor:   .multicolor
        }
    }
}

// MARK: - SF Symbol Weight

/// Controls the weight of SF Symbols. Should match adjacent text weight
/// per HIG 2026 §Symbols: "Match symbol weight to adjacent text weight."
enum SkinSymbolWeight: String, Equatable, CaseIterable, Codable {
    case ultraLight
    case thin
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy
    case black

    var swiftUIWeight: Font.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin:       .thin
        case .light:      .light
        case .regular:    .regular
        case .medium:     .medium
        case .semibold:   .semibold
        case .bold:       .bold
        case .heavy:      .heavy
        case .black:      .black
        }
    }

    /// Numeric index for computing weight distance (HIG warns if delta > 2).
    var weightIndex: Int {
        switch self {
        case .ultraLight: 0
        case .thin:       1
        case .light:      2
        case .regular:    3
        case .medium:     4
        case .semibold:   5
        case .bold:       6
        case .heavy:      7
        case .black:      8
        }
    }
}

// MARK: - Badge Style

/// Controls how badges and pills are rendered.
/// Apple HIG 2026 §Color: "Tinted backgrounds must maintain ≥ 3:1 contrast."
enum SkinBadgeStyle: String, Equatable, CaseIterable, Codable {
    /// Solid fill with accent color.
    case filled
    /// Outline stroke with no fill.
    case outlined
    /// Subtle tinted background (default, current behavior).
    case tinted
}

// MARK: - Separator Style

/// Controls how dividers/separators appear.
/// Apple HIG 2026 §Layout: "Omit dividers only when spatial grouping
/// provides sufficient separation."
enum SkinSeparatorStyle: String, Equatable, CaseIterable, Codable {
    /// Standard system separator.
    case system
    /// Thinner, lower-contrast separator.
    case subtle
    /// Accent-colored separator.
    case accent
    /// No separator (use only with card-style layouts).
    case none
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
/// All skins — both built-in and custom — are defined as `.json` JSON files.
/// See `TEMPLATE.json` for the format and `CONTRIBUTING_SKINS.md` for full
/// instructions. Built-in skins live in `Bubo/Skins/BuiltInSkins/`.
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
    /// Defaults to `.regular`.
    let buttonMaterial: SkinBarMaterial

    /// Optional color overlay on button material (glass-style primary buttons).
    /// Falls back to accentColor when nil.
    let buttonTint: Color?

    /// Opacity of the button tint overlay (0 = invisible, typically 0.15–0.35).
    /// Defaults to 0.3 for glass buttons.
    let buttonTintOpacity: Double

    /// Optional accent color override used exclusively for primary button backgrounds.
    /// When set, the primary button gradient uses this instead of the skin's main accentColor,
    /// allowing a skin to have one overall accent (e.g. silver) while keeping vivid buttons.
    let buttonAccentColor: Color?

    /// Optional secondary accent override for the primary button gradient end color.
    /// Falls back to `buttonAccentColor?.opacity(0.85)` → `secondaryAccent` → `accentColor.opacity(0.85)`.
    let buttonSecondaryAccent: Color?

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

    // MARK: Layout & Depth (HIG 2026)

    /// Global corner radius for card/platter surfaces (default 12).
    let cornerRadius: CGFloat

    /// Ambient shadow opacity for elevated surfaces like popovers and tooltips.
    let shadowOpacity: Double

    /// Ambient shadow blur radius.
    let shadowRadius: CGFloat

    /// Vertical offset for the ambient shadow.
    let shadowY: CGFloat

    /// Opacity of a 1px intrinsic inner border (highlights glass materials).
    let platterBorderOpacity: Double

    // MARK: Advanced Interactions & Text (HIG 2026+)

    /// Semantic text primary color override.
    let textPrimary: Color?

    /// Semantic text secondary color override.
    let textSecondary: Color?

    /// Semantic text tertiary color override.
    let textTertiary: Color?

    /// Color for destructive actions (delete, remove). Falls back to system red.
    let destructiveColor: Color?

    /// Color for success states (confirmed, saved). Falls back to system green.
    let successColor: Color?

    /// Color for warning states (conflicts, alerts). Falls back to system orange.
    let warningColor: Color?

    /// Physics style for micro-interactions and modally-animated elements.
    let animationStyle: SkinAnimationStyle

    /// Hover shadow opacity (overrides ambient depth dynamically on mouse over).
    let hoverShadowOpacity: Double

    /// Hover shadow blur radius.
    let hoverShadowRadius: CGFloat

    /// Hover shadow vertical drop.
    let hoverShadowY: CGFloat

    /// Hover background fill layer opacity on interactive elements.
    let hoverFillOpacity: Double

    // MARK: Typography & Symbols (HIG 2026)

    /// System font design — SF Pro, SF Rounded, New York, or SF Mono.
    let fontDesign: SkinFontDesign

    /// Font weight for body text and buttons.
    let fontWeight: SkinFontWeight

    /// Font weight for section headers / headlines.
    let headlineFontWeight: SkinFontWeight

    /// SF Symbol rendering mode.
    let sfSymbolRendering: SkinSymbolRendering

    /// SF Symbol weight — should be close to fontWeight per HIG.
    let sfSymbolWeight: SkinSymbolWeight

    /// Badge/pill appearance style.
    let badgeStyle: SkinBadgeStyle

    /// Separator/divider appearance style.
    let separatorStyle: SkinSeparatorStyle

    /// Separator opacity (floor 0.15 when separatorStyle != .none).
    let separatorOpacity: Double

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
        buttonAccentColor: Color? = nil,
        buttonSecondaryAccent: Color? = nil,
        buttonMaterial: SkinBarMaterial = .regular,
        buttonTint: Color? = nil,
        buttonTintOpacity: Double = 0.3,
        toolbarTint: Color? = nil,
        barMaterial: SkinBarMaterial = .thick,
        barTint: Color? = nil,
        barTintOpacity: Double = 0,
        platterMaterial: SkinBarMaterial = .regular,
        platterTint: Color? = nil,
        platterTintOpacity: Double = 0,
        cornerRadius: CGFloat = 12,
        shadowOpacity: Double = 0.06,
        shadowRadius: CGFloat = 8,
        shadowY: CGFloat = 4,
        platterBorderOpacity: Double = 0,
        textPrimary: Color? = nil,
        textSecondary: Color? = nil,
        textTertiary: Color? = nil,
        destructiveColor: Color? = nil,
        successColor: Color? = nil,
        warningColor: Color? = nil,
        animationStyle: SkinAnimationStyle = .smooth,
        hoverShadowOpacity: Double = 0.12,
        hoverShadowRadius: CGFloat = 12,
        hoverShadowY: CGFloat = 6,
        hoverFillOpacity: Double = 0.06,
        fontDesign: SkinFontDesign = .rounded,
        fontWeight: SkinFontWeight = .semibold,
        headlineFontWeight: SkinFontWeight = .semibold,
        sfSymbolRendering: SkinSymbolRendering = .hierarchical,
        sfSymbolWeight: SkinSymbolWeight = .medium,
        badgeStyle: SkinBadgeStyle = .tinted,
        separatorStyle: SkinSeparatorStyle = .system,
        separatorOpacity: Double = 0.5
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
        self.buttonAccentColor = buttonAccentColor
        self.buttonSecondaryAccent = buttonSecondaryAccent
        self.buttonMaterial = buttonMaterial
        self.buttonTint = buttonTint
        self.buttonTintOpacity = buttonTintOpacity
        self.toolbarTint = toolbarTint
        self.barMaterial = barMaterial
        self.barTint = barTint
        self.barTintOpacity = barTintOpacity
        self.platterMaterial = platterMaterial
        self.platterTint = platterTint
        self.platterTintOpacity = platterTintOpacity
        self.cornerRadius = cornerRadius
        self.shadowOpacity = shadowOpacity
        self.shadowRadius = shadowRadius
        self.shadowY = shadowY
        self.platterBorderOpacity = platterBorderOpacity
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.destructiveColor = destructiveColor
        self.successColor = successColor
        self.warningColor = warningColor
        self.animationStyle = animationStyle
        self.hoverShadowOpacity = hoverShadowOpacity
        self.hoverShadowRadius = hoverShadowRadius
        self.hoverShadowY = hoverShadowY
        self.hoverFillOpacity = hoverFillOpacity
        self.fontDesign = fontDesign
        self.fontWeight = fontWeight
        self.headlineFontWeight = headlineFontWeight
        self.sfSymbolRendering = sfSymbolRendering
        self.sfSymbolWeight = sfSymbolWeight
        self.badgeStyle = badgeStyle
        self.separatorStyle = separatorStyle
        // HIG: floor at 0.15 when separators are visible
        self.separatorOpacity = separatorStyle != .none ? max(0.15, separatorOpacity) : separatorOpacity
    }

    // MARK: - Derived

    /// Resolved secondary accent, falling back to a darkened version of accentColor.
    var resolvedSecondaryAccent: Color {
        secondaryAccent ?? accentColor.opacity(0.85)
    }

    /// Resolved accent color for primary buttons. Falls back to main accentColor.
    var resolvedButtonAccentColor: Color {
        buttonAccentColor ?? accentColor
    }

    /// Resolved secondary accent for primary button gradient.
    /// Falls back to buttonAccentColor's secondary → skin secondaryAccent → accentColor dimmed.
    var resolvedButtonSecondaryAccent: Color {
        buttonSecondaryAccent
            ?? buttonAccentColor.map { $0.opacity(0.85) }
            ?? resolvedSecondaryAccent
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

    /// Resolved button tint color, falling back to accentColor.
    var resolvedButtonTint: Color {
        buttonTint ?? accentColor
    }

    /// Whether this skin has a custom bar tint overlay.
    var hasBarTint: Bool {
        barTint != nil && barTintOpacity > 0
    }

    /// Resolved SwiftUI `Material` for platter/card surfaces.
    var resolvedPlatterMaterial: Material {
        platterMaterial.material
    }

    /// Primary ambient shadow color for elevated components.
    var resolvedShadowColor: Color {
        Color.black.opacity(shadowOpacity)
    }

    /// Primary hover shadow color for elevated components.
    var resolvedHoverShadowColor: Color {
        Color.black.opacity(hoverShadowOpacity)
    }

    /// Resolved hover fill layer overlay (used for rows and interactive elements).
    var resolvedHoverFill: Color {
        if prefersDarkTint {
            return Color.white.opacity(hoverFillOpacity)
        } else {
            return Color.black.opacity(hoverFillOpacity)
        }
    }

    /// Resolved semantic properties matching `DS.Colors` defaults if unmodified.
    var resolvedTextPrimary: Color {
        textPrimary ?? Color(nsColor: .labelColor)
    }

    var resolvedTextSecondary: Color {
        textSecondary ?? Color(nsColor: .secondaryLabelColor)
    }

    var resolvedTextTertiary: Color {
        textTertiary ?? Color(nsColor: .tertiaryLabelColor)
    }

    /// Resolved destructive action color, falling back to system red.
    var resolvedDestructiveColor: Color {
        destructiveColor ?? .red
    }

    /// Resolved success state color, falling back to system green.
    var resolvedSuccessColor: Color {
        successColor ?? .green
    }

    /// Resolved warning state color, falling back to system orange.
    var resolvedWarningColor: Color {
        warningColor ?? .orange
    }

    /// Resolved animation matching the skin's physical properties.
    var resolvedMicroAnimation: Animation {
        animationStyle.swiftUIAnimation
    }

    /// Resolved SwiftUI Font.Design for body text.
    var resolvedFontDesign: Font.Design {
        fontDesign.swiftUIDesign
    }

    /// Resolved SwiftUI Font.Weight for body/buttons.
    var resolvedFontWeight: Font.Weight {
        fontWeight.swiftUIWeight
    }

    /// Resolved SwiftUI Font.Weight for headlines.
    var resolvedHeadlineFontWeight: Font.Weight {
        headlineFontWeight.swiftUIWeight
    }

    /// Resolved SF Symbol rendering mode.
    var resolvedSymbolRendering: SymbolRenderingMode {
        sfSymbolRendering.swiftUIMode
    }

    /// Resolved SF Symbol weight.
    var resolvedSymbolWeight: Font.Weight {
        sfSymbolWeight.swiftUIWeight
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
/// **To add a new built-in skin:**
/// 1. Create a `.json` JSON file in `Bubo/Skins/BuiltInSkins/`
///    (copy `TEMPLATE.json` as a starting point)
/// 2. Add its ID to the `order` array in `BuiltInSkinLoader`
///
/// That's it — your skin will appear in Settings automatically.
///
/// Users can also create custom `.json` files and import them
/// via Settings — no code changes needed. See `CustomSkinLoader` for details.
enum SkinCatalog {
    /// All built-in skins loaded from bundled `.json` JSON files.
    /// Guaranteed to contain at least one skin (Classic fallback).
    static let builtInSkins: [SkinDefinition] = BuiltInSkinLoader.skins

    /// All skins including user-imported custom skins.
    static var allSkins: [SkinDefinition] {
        builtInSkins + CustomSkinLoader.shared.customSkins
    }

    /// Look up a skin by its ID. Falls back to "classic", then first available.
    static func skin(forID id: String) -> SkinDefinition {
        allSkins.first { $0.id == id }
            ?? builtInSkins.first { $0.id == "classic" }
            ?? builtInSkins[0]  // safe: BuiltInSkinLoader guarantees ≥ 1
    }

    /// The default skin.
    static var defaultSkin: SkinDefinition {
        builtInSkins.first { $0.id == "system" }
            ?? builtInSkins[0]  // safe: BuiltInSkinLoader guarantees ≥ 1
    }
}
