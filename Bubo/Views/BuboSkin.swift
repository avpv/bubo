import SwiftUI

// MARK: - Skin Background View

struct SkinBackgroundLayer: View {
    let skin: SkinDefinition
    var skinImageOverride: SkinImageOverride? = nil

    var body: some View {
        if skin.isClassic {
            Color.clear
        } else {
            ZStack {
                // User-chosen background image for this skin
                if let override = skinImageOverride,
                   !override.imagePath.isEmpty,
                   let nsImage = NSImage(contentsOfFile: override.imagePath) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: override.fillMode == "fit" ? .fit : .fill)
                        .opacity(override.opacity)
                        .blur(radius: override.blur)
                        .clipped()
                }

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

