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

/// Allowed font weights for skins. Apple's design system prescribes only
/// weights **300 / 400 / 600 / 700**; weight 500 (`.medium`) is explicitly
/// forbidden. Bubo additionally excludes 300 (`.light`) and 200 (`.thin`)
/// per HIG legibility rules — leaving regular / semibold / bold.
/// Headline and SF Symbol weights are derived from this single value.
enum SkinFontWeight: String, Equatable, CaseIterable, Codable {
    case regular
    case semibold
    case bold

    var swiftUIWeight: Font.Weight {
        switch self {
        case .regular:  .regular
        case .semibold: .semibold
        case .bold:     .bold
        }
    }
}

// MARK: - Dark Mood Mode

/// How a skin handles dark/light mood relative to the system appearance.
///
///   `.auto`  — follow `@Environment(\.colorScheme)`. The skin's tint &
///              shadow choices flip between light and dark mood when the
///              user toggles Apple's system appearance. **Default for every
///              built-in skin** so the catalog feels like first-class macOS
///              software rather than a frozen art piece.
///   `.light` — force the light-mood derived treatment regardless of system
///              appearance. Use for skins whose authored visual identity
///              only makes sense in light context (e.g., a pastel paper).
///   `.dark`  — force the dark-mood derived treatment regardless of system
///              appearance. Use for skins whose authored visual identity
///              only makes sense in dark context (e.g., a midnight neon).
///
/// The authored `prefersDarkTint: Bool` field on `SkinDefinition` is the
/// **fallback** value used when `darkMoodMode == .auto` is queried without
/// a `ColorScheme` (i.e., in code paths that don't have View context).
enum SkinDarkMoodMode: String, Equatable, CaseIterable, Codable {
    case auto
    case light
    case dark
}


// MARK: - Font Design

/// System font face used by a skin. SF Rounded reads as friendly/utility
/// (Apple Clock, Fitness, HomeKit). SF Pro Text/Display (`.default`) is
/// Apple's marketing-site face and what Apple.com / Settings.app use.
/// Mono/serif are escape hatches for stylized skins.
enum SkinFontDesign: String, Equatable, CaseIterable, Codable {
    case rounded
    case `default`
    case serif
    case monospaced

    var swiftUIDesign: Font.Design {
        switch self {
        case .rounded:    .rounded
        case .default:    .default
        case .serif:      .serif
        case .monospaced: .monospaced
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

    /// Authored dark-mood fallback. Used when `darkMoodMode == .auto` and
    /// no `ColorScheme` is available — keeps every code path that reads
    /// `skin.prefersDarkTint` working without view-context.
    ///
    /// View-level surfaces (background blend, shadows, surface tint)
    /// should prefer `effectivePrefersDarkTint(in:)` so they follow the
    /// system appearance when the skin is authored as `.auto`.
    let prefersDarkTint: Bool

    /// How this skin reconciles its mood with the system appearance.
    /// Default `.auto` — built-in skins follow Apple's light/dark toggle.
    let darkMoodMode: SkinDarkMoodMode

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

    /// System font design (face family). Defaults to `.rounded` — Bubo's
    /// historical voice. The Apple-marketing-site skin opts in to
    /// `.default` (SF Pro Text/Display).
    let fontDesign: SkinFontDesign

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
        darkMoodMode: SkinDarkMoodMode = .auto,
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
        fontDesign: SkinFontDesign = .rounded,
        badgeStyle: SkinBadgeStyle = .tinted,
        separatorStyle: SkinSeparatorStyle = .subtle
    ) {
        self.id = id
        self.displayName = displayName
        self.author = author
        self.accentColor = accentColor
        self.prefersDarkTint = prefersDarkTint
        self.darkMoodMode = darkMoodMode
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
        self.fontDesign = fontDesign
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
    var resolvedBarMaterial: Material { .thin }

    /// Material used for card/platter surfaces.
    var resolvedPlatterMaterial: Material { .ultraThin }

    /// Material used as the base for glass-style and secondary buttons.
    var resolvedButtonMaterial: Material { .thin }

    /// System font design (face family). Driven by the skin's `fontDesign`.
    /// Defaults to `.rounded` — Bubo's historical SF Rounded voice — so
    /// existing skins keep their look unless they opt in to a different face.
    var resolvedFontDesign: Font.Design { fontDesign.swiftUIDesign }

    /// Headline font weight — one step bolder than body weight, capped at bold.
    /// Apple's allowed weights only (no 500).
    var resolvedHeadlineFontWeight: Font.Weight {
        switch fontWeight {
        case .regular:  return .semibold
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

    /// Inner-glass border opacity for platters — a hairline edge that
    /// reads quietly under the surface content, the native macOS card
    /// treatment.
    var platterBorderOpacity: Double { 0.15 }

    /// Ambient shadow blur radius for elevated surfaces. Native macOS
    /// gives cards/popovers a soft, real ambient shadow so layers read as
    /// distinct planes — depth is restored here after the over-flat 2026
    /// pass crushed surfaces into a single muddy plane.
    var shadowRadius: CGFloat { 14 }

    /// Ambient shadow vertical offset — light comes from above, so the
    /// surface casts a short, soft drop beneath it.
    var shadowY: CGFloat { 4 }

    /// Hover shadow blur radius — one elevation step above ambient so a
    /// focused surface lifts perceptibly without ballooning.
    var hoverShadowRadius: CGFloat { 20 }

    /// Hover shadow vertical offset — keeps a gentle ratio against
    /// `shadowY` so depth grows proportionally on focus.
    var hoverShadowY: CGFloat { 6 }

    /// Hover background fill opacity on interactive elements.
    var hoverFillOpacity: Double { 0.08 }

    /// Opacity of glass-button tint overlay.
    var buttonTintOpacity: Double { 0.2 }

    // MARK: - Derived from mood (system-appearance reactive)

    /// Effective dark/light mood for a given system appearance. Skins
    /// authored as `.auto` (Apple's default behavior) follow the user's
    /// system Light/Dark toggle; `.light` / `.dark` skins force their
    /// authored mood regardless of system appearance.
    ///
    /// Call from view contexts that have `@Environment(\.colorScheme)`
    /// — typically `AppBackgroundLayer`, shadows on hover-rich surfaces,
    /// and any place that distinguishes "light wash" from "dark wash".
    func effectivePrefersDarkTint(in colorScheme: ColorScheme) -> Bool {
        switch darkMoodMode {
        case .light: return false
        case .dark:  return true
        case .auto:  return colorScheme == .dark
        }
    }

    /// Ambient shadow opacity — native depth. Dark mood casts slightly
    /// heavier shadows. Static accessor uses the authored fallback (no
    /// view context); pair with `shadowOpacity(in:)` from a view to follow
    /// the system appearance.
    var shadowOpacity: Double { prefersDarkTint ? 0.15 : 0.12 }

    func shadowOpacity(in colorScheme: ColorScheme) -> Double {
        effectivePrefersDarkTint(in: colorScheme) ? 0.15 : 0.12
    }

    /// Hover shadow opacity — one step above ambient on focus.
    var hoverShadowOpacity: Double { prefersDarkTint ? 0.24 : 0.18 }

    func hoverShadowOpacity(in colorScheme: ColorScheme) -> Double {
        effectivePrefersDarkTint(in: colorScheme) ? 0.24 : 0.18
    }

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

    /// Surface tint opacity — the whole-window mood wash. Kept to a faint
    /// breath of accent so the canvas reads as a clean, near-neutral macOS
    /// window surface rather than a saturated colour field. (Classic, the
    /// native default, skips this wash entirely — see `AppBackgroundLayer`.)
    /// Static accessor uses the authored fallback; pair with the
    /// `(in:)` variant from view code to follow the system appearance.
    var resolvedSurfaceTintOpacity: Double {
        prefersDarkTint ? 0.06 : 0.03
    }

    func resolvedSurfaceTintOpacity(in colorScheme: ColorScheme) -> Double {
        effectivePrefersDarkTint(in: colorScheme) ? 0.06 : 0.03
    }

    /// Whether this skin has a custom bar tint overlay.
    var hasBarTint: Bool {
        barTint != nil && barTintOpacity > 0
    }

    // MARK: - Shadow colors

    var resolvedShadowColor: Color {
        Color.black.opacity(shadowOpacity)
    }

    func resolvedShadowColor(in colorScheme: ColorScheme) -> Color {
        Color.black.opacity(shadowOpacity(in: colorScheme))
    }

    var resolvedHoverShadowColor: Color {
        Color.black.opacity(hoverShadowOpacity)
    }

    func resolvedHoverShadowColor(in colorScheme: ColorScheme) -> Color {
        Color.black.opacity(hoverShadowOpacity(in: colorScheme))
    }

    var resolvedHoverFill: Color {
        if prefersDarkTint {
            return Color.white.opacity(hoverFillOpacity)
        } else {
            return Color.black.opacity(hoverFillOpacity)
        }
    }

    func resolvedHoverFill(in colorScheme: ColorScheme) -> Color {
        effectivePrefersDarkTint(in: colorScheme)
            ? Color.white.opacity(hoverFillOpacity)
            : Color.black.opacity(hoverFillOpacity)
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
        // Accent participates because `adaptedToBackdrop(_:)` produces
        // same-id copies that differ only in the readable accent — the
        // environment must propagate that change when the wallpaper flips.
        lhs.id == rhs.id && lhs.accentColor == rhs.accentColor
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

    /// The default skin. Prefers Classic — the native macOS look: the
    /// system accent, window-material background with no colour wash, and
    /// native vibrancy throughout. Falls back to System, then Apple.
    static var defaultSkin: SkinDefinition {
        builtInSkins.first { $0.id == "classic" }
            ?? builtInSkins.first { $0.id == "system" }
            ?? builtInSkins.first { $0.id == "apple" }
            ?? builtInSkins[0]  // safe: BuiltInSkinLoader guarantees ≥ 1
    }
}
