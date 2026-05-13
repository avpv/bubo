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

// MARK: - Font Weight

/// Allowed font weights for skins. Excludes ultraLight/thin per HIG legibility rules.
/// Birman: a skin should pick ONE body weight, not three. Headline/symbol weights
/// are derived from this one value.
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

// MARK: - Badge Style

/// Controls how badges and pills are rendered.
enum SkinBadgeStyle: String, Equatable, CaseIterable, Codable {
    /// Solid fill with accent color.
    case filled
    /// Outline stroke with no fill.
    case outlined
    /// Subtle tinted background (default).
    case tinted
}

// MARK: - Separator Style

/// Controls how dividers/separators appear.
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

// MARK: - Skin Definition

/// A complete visual theme for Bubo.
///
/// Birman: a skin author should think about **mood**, not about
/// `shadowY: 10 vs 8`. This type stores only the handful of values that
/// actually differ between skins. Layout depth, materials, typography
/// scale, semantic colors and animation physics are fixed globally so
/// they can't be configured into an unreadable state.
///
/// All skins — both built-in and custom — are defined as `.json` JSON files.
/// See `TEMPLATE.json` for the shape and `buboskin.schema.json` for the
/// authoritative validation rules. Built-in skins live in
/// `Bubo/Presentation/Skins/BuiltInSkins/`. The design rationale behind this API lives in
/// `docs/design/PRINCIPLES.md`.
struct SkinDefinition: Identifiable, Equatable {

    // MARK: Identity

    /// Unique identifier — used for persistence. Must be stable across versions.
    let id: String

    /// Display name shown in the skin picker.
    let displayName: String

    /// Author name / GitHub handle.
    let author: String

    // MARK: Mood

    /// Primary accent color used for buttons, highlights, and tint.
    let accentColor: Color

    /// Whether this skin has a dark-tinted mood (affects blend modes and
    /// derived shadow/hover depths).
    let prefersDarkTint: Bool

    /// Background gradient specification — the "wallpaper" feel of the skin.
    let backgroundGradient: SkinGradient

    /// 1–2 colors used for the skin picker thumbnail.
    let previewColors: [Color]

    /// Optional secondary accent (e.g. for gradient end-point). Falls back to a
    /// dimmed version of `accentColor`.
    let secondaryAccent: Color?

    // MARK: Surface Tints (optional)

    /// Optional color overlay on top of the bar material. Encode opacity in
    /// the color itself (`"#1A1F4014"`) or use the default
    /// `barTintOpacity`.
    let barTint: Color?

    /// Opacity of the bar tint overlay. Defaults to 0.08 when `barTint` is set.
    let barTintOpacity: Double

    /// Optional color overlay on platter/card surfaces.
    let platterTint: Color?

    /// Opacity of the platter tint overlay. Defaults to 0.05 when `platterTint` is set.
    let platterTintOpacity: Double

    // MARK: Buttons

    /// Button fill style — controls primary button appearance.
    let buttonStyle: SkinButtonStyle

    /// Shape used for button clipping and hit-testing.
    let buttonShape: SkinButtonShape

    /// Explicit foreground color for primary buttons. Overrides the automatic
    /// luminance-based contrast logic when set.
    let buttonColor: Color?

    /// Optional accent override for primary button backgrounds only. Lets a
    /// skin have one overall accent (e.g. silver) while keeping vivid buttons.
    let buttonAccentColor: Color?

    /// Optional secondary accent override for the primary button gradient end
    /// color.
    let buttonSecondaryAccent: Color?

    /// Optional color overlay on glass-style primary buttons. Falls back to
    /// `accentColor`.
    let buttonTint: Color?

    // MARK: Typography

    /// Body/button font weight. Headline and SF Symbol weights are derived
    /// from this value (HIG: "match symbol weight to adjacent text weight").
    let fontWeight: SkinFontWeight

    // MARK: Appearance

    /// Badge/pill appearance style.
    let badgeStyle: SkinBadgeStyle

    /// Separator/divider appearance style.
    let separatorStyle: SkinSeparatorStyle

    init(
        id: String,
        displayName: String,
        author: String,
        accentColor: Color,
        prefersDarkTint: Bool,
        backgroundGradient: SkinGradient,
        previewColors: [Color],
        secondaryAccent: Color? = nil,
        barTint: Color? = nil,
        barTintOpacity: Double = 0.08,
        platterTint: Color? = nil,
        platterTintOpacity: Double = 0.05,
        buttonStyle: SkinButtonStyle = .gradient,
        buttonShape: SkinButtonShape = .capsule,
        buttonColor: Color? = nil,
        buttonAccentColor: Color? = nil,
        buttonSecondaryAccent: Color? = nil,
        buttonTint: Color? = nil,
        fontWeight: SkinFontWeight = .regular,
        badgeStyle: SkinBadgeStyle = .tinted,
        separatorStyle: SkinSeparatorStyle = .subtle
    ) {
        self.id = id
        self.displayName = displayName
        self.author = author
        self.accentColor = accentColor
        self.prefersDarkTint = prefersDarkTint
        self.backgroundGradient = backgroundGradient
        self.previewColors = previewColors
        self.secondaryAccent = secondaryAccent
        self.barTint = barTint
        self.barTintOpacity = barTintOpacity
        self.platterTint = platterTint
        self.platterTintOpacity = platterTintOpacity
        self.buttonStyle = buttonStyle
        self.buttonShape = buttonShape
        self.buttonColor = buttonColor
        self.buttonAccentColor = buttonAccentColor
        self.buttonSecondaryAccent = buttonSecondaryAccent
        self.buttonTint = buttonTint
        self.fontWeight = fontWeight
        self.badgeStyle = badgeStyle
        self.separatorStyle = separatorStyle
    }

    // MARK: - Fixed layout constants (not authorable)
    //
    // Birman: these values are the same for every skin in the catalog. Making
    // them configurable would only let authors break the layout rhythm. If a
    // future skin genuinely needs a different depth, promote the value back to
    // a stored field.

    /// Material used for header/footer bars.
    var resolvedBarMaterial: Material { .thick }

    /// Material used for card/platter surfaces.
    var resolvedPlatterMaterial: Material { .regular }

    /// Material used as the base for glass-style and secondary buttons.
    var resolvedButtonMaterial: Material { .regular }

    /// System font design — all Bubo skins use SF Rounded.
    var resolvedFontDesign: Font.Design { .rounded }

    /// Headline font weight — one step bolder than body weight, capped at bold.
    var resolvedHeadlineFontWeight: Font.Weight {
        switch fontWeight {
        case .regular:  return .semibold
        case .medium:   return .semibold
        case .semibold: return .bold
        case .bold:     return .bold
        }
    }

    /// SF Symbol rendering mode. HIG: hierarchical for utility apps.
    var resolvedSymbolRendering: SymbolRenderingMode { .hierarchical }

    /// SF Symbol weight — HIG: "match symbol weight to adjacent text weight".
    var resolvedSymbolWeight: Font.Weight { fontWeight.swiftUIWeight }

    /// Toolbar icon size in points.
    var toolbarIconSize: CGFloat { 15 }

    /// Inner-glass border opacity for platters.
    var platterBorderOpacity: Double { 0.25 }

    /// Ambient shadow blur radius for elevated surfaces.
    var shadowRadius: CGFloat { 16 }

    /// Ambient shadow vertical offset.
    var shadowY: CGFloat { 8 }

    /// Hover shadow blur radius.
    var hoverShadowRadius: CGFloat { 18 }

    /// Hover shadow vertical offset.
    var hoverShadowY: CGFloat { 10 }

    /// Hover background fill opacity on interactive elements.
    var hoverFillOpacity: Double { 0.08 }

    /// Opacity of glass-button tint overlay.
    var buttonTintOpacity: Double { 0.2 }

    // MARK: - Derived from mood

    /// Ambient shadow opacity — dark skins cast slightly heavier shadows.
    var shadowOpacity: Double { prefersDarkTint ? 0.15 : 0.12 }

    /// Hover shadow opacity — same rule as ambient.
    var hoverShadowOpacity: Double { prefersDarkTint ? 0.25 : 0.18 }

    /// Separator opacity — `.system` reads slightly stronger to match
    /// native dividers.
    var separatorOpacity: Double {
        switch separatorStyle {
        case .none:   return 0
        case .subtle: return 0.15
        case .system: return 0.25
        case .accent: return 0.25
        }
    }

    /// Micro-interaction animation — one physics profile for the whole app.
    /// Birman: a product has one motion signature, not three.
    var resolvedMicroAnimation: Animation {
        .spring(duration: 0.35, bounce: 0.25)
    }

    // MARK: - Derived from accent

    /// Resolved secondary accent, falling back to a dimmed main accent.
    var resolvedSecondaryAccent: Color {
        secondaryAccent ?? accentColor.opacity(0.85)
    }

    /// Resolved accent color for primary buttons. Falls back to `accentColor`.
    var resolvedButtonAccentColor: Color {
        buttonAccentColor ?? accentColor
    }

    /// Resolved secondary accent for primary button gradient end-point.
    var resolvedButtonSecondaryAccent: Color {
        buttonSecondaryAccent
            ?? buttonAccentColor.map { $0.opacity(0.85) }
            ?? resolvedSecondaryAccent
    }

    /// Resolved button tint (for glass style). Falls back to `accentColor`.
    var resolvedButtonTint: Color {
        buttonTint ?? accentColor
    }

    /// Toolbar tint — secondary actions are visually subordinate to primary
    /// CTAs. Derived as a dimmed accent; no per-skin override.
    var resolvedToolbarTint: Color {
        accentColor.opacity(0.7)
    }

    // MARK: - Surface tint (derived from mood)

    /// Whole-window background mood overlay. Applied in `AppBackgroundLayer`.
    var resolvedSurfaceTint: Color { accentColor }

    /// Surface tint opacity — darker skins carry a heavier mood wash.
    var resolvedSurfaceTintOpacity: Double {
        prefersDarkTint ? 0.12 : 0.05
    }

    /// Whether this skin has a custom bar tint overlay.
    var hasBarTint: Bool {
        barTint != nil && barTintOpacity > 0
    }

    // MARK: - Shadow colors

    var resolvedShadowColor: Color {
        Color.black.opacity(shadowOpacity)
    }

    var resolvedHoverShadowColor: Color {
        Color.black.opacity(hoverShadowOpacity)
    }

    var resolvedHoverFill: Color {
        if prefersDarkTint {
            return Color.white.opacity(hoverFillOpacity)
        } else {
            return Color.black.opacity(hoverFillOpacity)
        }
    }

    // MARK: - Semantic colors (system)
    //
    // Birman: semantic colors (error/success/warning) are not decoration.
    // They carry meaning and must stay consistent across skins so the user
    // can recognise them at a glance. All skins use the system values.

    var resolvedDestructiveColor: Color { Color(nsColor: .systemRed) }
    var resolvedSuccessColor: Color { Color(nsColor: .systemGreen) }
    var resolvedWarningColor: Color { Color(nsColor: .systemOrange) }

    // MARK: - Urgent vs Destructive (two intensities of the same hue)
    //
    // Before this split, the same `systemRed` was painted onto three things
    // at once: the over-capacity ring, the urgent-task left stripe, and the
    // «1 urgent» pill in the header. Three full-saturation reds compete for
    // the same eye-fix and the page reads as «alarm» when only one signal is
    // actually destructive.
    //
    // The fix is **one hue, two intensities**:
    //   - `resolvedDestructiveColor`  — saturated red. *The* hard problem
    //     («over capacity», failed sync). Used by the capacity ring's
    //     `.over` band and by the warning triangle.
    //   - `resolvedUrgentColor` — same hue, desaturated. Informational
    //     («this task is due soon»). Used by the left stripe of urgent
    //     `BacklogTaskRow`s and by the «N urgent» header pill.
    //
    // The eye reads the two as related (same family) without competing.
    // Birman: «one signal — one color; intensity encodes priority,
    // not hue».
    //
    // Both default to derivations of `systemRed` so existing skins keep
    // their current look without per-skin JSON edits — a future revision
    // can override per skin when the `capacityRamp` lands.
    var resolvedUrgentColor: Color {
        // 0.7 alpha damps the saturation just enough that the urgent stripe
        // and pill read as «warm but lower-priority», while still being
        // unambiguously of the red family.
        Color(nsColor: .systemRed).opacity(0.7)
    }

    // MARK: - Energy ramp (peak ↔ low tint)
    //
    // Two-stop gradient anchors the «peak energy» / «low energy» visual
    // language across the app — the `EventRowView`'s ⚡/🍃 glyph reads
    // accent vs. tertiary today, but a future timeline overlay (planned
    // in /root/.claude/plans/soft-scribbling-dragonfly.md) tints the
    // hourly band by predicted energy and reads from these two stops.
    //
    // Defaults derive from the skin's accent (peak) and a desaturated
    // tertiary (low). Skin authors who want a cool-blue → warm-amber
    // ramp can override per-skin once the overlay lands.

    /// Tint for «peak energy» hours / contexts. Defaults to the skin's
    /// own accent so the ⚡-marker reads as the user's own brand colour.
    var resolvedPeakEnergyColor: Color { accentColor }

    /// Tint for «low energy» hours / contexts. Defaults to a soft
    /// tertiary-green family so it reads as «calm, low-output», not
    /// «warning». The 🍃 glyph picks it up via `resolvedTextTertiary`
    /// today; the future timeline overlay can use this stop directly.
    var resolvedLowEnergyColor: Color {
        Color(nsColor: .systemGreen).opacity(0.6)
    }

    // MARK: - Text colors (system)

    var resolvedTextPrimary: Color { Color(nsColor: .labelColor) }
    var resolvedTextSecondary: Color { Color(nsColor: .secondaryLabelColor) }
    var resolvedTextTertiary: Color { Color(nsColor: .tertiaryLabelColor) }

    // MARK: - Resolved font weights

    /// Resolved SwiftUI Font.Weight for body/buttons.
    var resolvedFontWeight: Font.Weight {
        fontWeight.swiftUIWeight
    }

    // MARK: - Preview

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
/// 1. Create a `.json` JSON file in `Bubo/Presentation/Skins/BuiltInSkins/`
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
