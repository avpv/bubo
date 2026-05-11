import SwiftUI

// MARK: - Skin Background View

struct SkinBackgroundLayer: View {
    let skin: SkinDefinition


    var body: some View {
        if skin.isClassic {
            Color.clear
        } else {
            ZStack {


                // Gradient overlay
                skinGradient
                    .blendMode(skin.prefersDarkTint ? .plusLighter : .plusDarker)
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var skinGradient: some View {
        let spec = skin.backgroundGradient
        switch spec.style {
        case .linear(let start, let end):
            LinearGradient(
                gradient: Gradient(colors: spec.colors),
                startPoint: start,
                endPoint: end
            )
        case .radial(let center, let startRadius, let endRadius):
            RadialGradient(
                gradient: Gradient(colors: spec.colors),
                center: center,
                startRadius: startRadius,
                endRadius: endRadius
            )
        }
    }
}

// MARK: - Skin Tint Modifier

struct SkinTintModifier: ViewModifier {
    let skin: SkinDefinition

    func body(content: Content) -> some View {
        content
            .tint(skin.accentColor)
            .symbolRenderingMode(skin.resolvedSymbolRendering)
            .fontWeight(skin.resolvedSymbolWeight)
    }
}

extension View {
    func skinTinted(_ skin: SkinDefinition) -> some View {
        modifier(SkinTintModifier(skin: skin))
    }
}

// MARK: - Skin Typography Modifier

/// Applies the skin's font design and weight to body text.
struct SkinTypographyModifier: ViewModifier {
    let skin: SkinDefinition

    func body(content: Content) -> some View {
        content
            .fontDesign(skin.resolvedFontDesign)
            .fontWeight(skin.resolvedFontWeight)
    }
}

extension View {
    /// Applies the skin's typography (font design + weight) to this view hierarchy.
    func skinTypography(_ skin: SkinDefinition) -> some View {
        modifier(SkinTypographyModifier(skin: skin))
    }
}

// MARK: - Skin Separator

/// A separator that respects the active skin's separator style and opacity.
struct SkinSeparator: View {
    @Environment(\.activeSkin) private var skin

    var body: some View {
        switch skin.separatorStyle {
        case .system:
            Divider()
                .opacity(skin.separatorOpacity)
        case .subtle:
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)
                .opacity(skin.separatorOpacity * 0.6)
        case .accent:
            Rectangle()
                .fill(skin.accentColor)
                .frame(height: 1)
                .opacity(skin.separatorOpacity)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Bar Background

/// Composable background for header/footer bars: base material + optional color tint overlay.
struct SkinBarBackground: View {
    let skin: SkinDefinition

    var body: some View {
        ZStack {
            Rectangle().fill(skin.resolvedBarMaterial)
            if let tint = skin.barTint, skin.barTintOpacity > 0 {
                tint.opacity(skin.barTintOpacity)
            }
        }
    }
}

extension View {
    /// Applies the skin's bar background (material + optional tint) as a background layer.
    func skinBarBackground(_ skin: SkinDefinition) -> some View {
        background(SkinBarBackground(skin: skin))
    }
}

// MARK: - Platter Background

/// Composable background for card/platter surfaces: base material + optional color tint overlay.
struct SkinPlatterBackground: View {
    let skin: SkinDefinition

    var body: some View {
        ZStack {
            Rectangle().fill(skin.resolvedPlatterMaterial)
            if let tint = skin.platterTint, skin.platterTintOpacity > 0 {
                tint.opacity(skin.platterTintOpacity)
            }
        }
    }
}

extension View {
    /// Applies the skin's platter background (material + optional tint) as a background layer.
    func skinPlatter(_ skin: SkinDefinition) -> some View {
        background(SkinPlatterBackground(skin: skin))
    }
}

// MARK: - Platter Shape & Depth (HIG 2026)

/// Inner glass border used on platter surfaces.
///
/// Honours `accessibilityReduceTransparency` by swapping the white-opacity
/// gradient + `plusLighter` blend for a solid `separatorColor` stroke when
/// the setting is on. The decorative glassmorphism disappears, but the
/// platter still has a visible edge — HIG: «Reduce Transparency substitutes
/// more opaque backgrounds for translucent ones; keep affordances visible».
///
/// Single source of truth for the border so `SkinPlatterDepthModifier` and
/// `skinTasksBlockChrome` stay in lockstep when the rules change.
struct PlatterGlassBorder: View {
    let skin: SkinDefinition

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
        if reduceTransparency {
            shape.strokeBorder(
                Color(nsColor: .separatorColor),
                lineWidth: DS.Border.thin
            )
        } else {
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(skin.platterBorderOpacity * 1.5),
                            .white.opacity(skin.platterBorderOpacity * 0.1),
                            .clear,
                            .white.opacity(skin.platterBorderOpacity * 0.4)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: DS.Border.thin
                )
                .blendMode(contrast == .increased ? .normal : .plusLighter)
        }
    }
}

/// Encapsulates corner radius, inner glass borders, and ambient drop shadows for
/// platters and elevated components using the skin's layout configuration.
///
/// Takes a `DS.Elevation` level (defaulting to `.z1` — the card plane). Pass
/// `.z2` for modal surfaces (CommandPalette, AddEventView) so they read as
/// «above the popover body». The contact shadow stays the same — it's the
/// short, sharp 2pt cue that anchors the surface to whatever is below; the
/// elevation modifier provides the longer ambient drop.
struct SkinPlatterDepthModifier: ViewModifier {
    let skin: SkinDefinition
    var level: DS.Elevation = .z1

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
            .overlay(PlatterGlassBorder(skin: skin))
            .elevation(level, skin: skin)
            // Secondary contact shadow — short, sharp, always present so the
            // platter «touches» the surface beneath regardless of z-plane.
            .shadow(
                color: skin.resolvedShadowColor,
                radius: 2,
                y: 1
            )
    }
}

extension View {
    /// Applies the skin's corner radius, inner glass border, and ambient
    /// shadow at the requested elevation plane.
    func skinPlatterDepth(_ skin: SkinDefinition, level: DS.Elevation = .z1) -> some View {
        modifier(SkinPlatterDepthModifier(skin: skin, level: level))
    }
}

// MARK: - Tasks-block chrome (drag-safe platter)
//
// Visual identity for the Tasks card surface used in two places:
//   • Inline on the main view, wrapping `BacklogView`.
//   • Fullscreen inside the fullscreen Backlog view
//     (`BacklogFullscreenView`), wrapping the same content distended
//     to popover height.
// One source of truth keeps the block recognizably the same object across
// collapsed and expanded states — Birman: «one object — one form».
//
// Why not `.skinPlatterDepth`? That modifier `clipShape`s the content
// itself, and on macOS the CALayer mask blocks NSDrag's hit testing —
// any `.draggable` row underneath would never initiate a drag session.
// We move the rounded clip onto the BACKGROUND layer so content stays
// unclipped and fully interactive.

extension View {
    /// Drag-safe Tasks-block chrome: same rounded platter background, glass
    /// border and ambient shadows as `skinPlatterDepth`, but the rounded clip
    /// lives on the background layer so `.draggable` rows underneath remain
    /// hit-testable. Used by both `BacklogView` (inline card) and the
    /// fullscreen Backlog (`BacklogFullscreenView`).
    func skinTasksBlockChrome(_ skin: SkinDefinition) -> some View {
        self
            .background(
                SkinPlatterBackground(skin: skin)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                    .shadow(color: skin.resolvedShadowColor, radius: skin.shadowRadius, y: skin.shadowY)
                    .shadow(color: skin.resolvedShadowColor, radius: 2, y: 1)
            )
            .overlay(
                PlatterGlassBorder(skin: skin)
                    .allowsHitTesting(false)
            )
    }
}

// MARK: - Environment Key

private struct ActiveSkinKey: EnvironmentKey {
    static let defaultValue: SkinDefinition = SkinCatalog.defaultSkin
}

extension EnvironmentValues {
    var activeSkin: SkinDefinition {
        get { self[ActiveSkinKey.self] }
        set { self[ActiveSkinKey.self] = newValue }
    }
}

