import SwiftUI

// MARK: - Skin Background View

struct SkinBackgroundLayer: View {
    let skin: SkinDefinition
    var skinImageOverride: SkinImageOverride? = nil
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        if skin.isClassic {
            Color.clear
        } else {
            ZStack {
                // User-chosen image takes priority over skin's bundled image
                if let override = skinImageOverride,
                   !override.imagePath.isEmpty,
                   let nsImage = NSImage(contentsOfFile: override.imagePath) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: override.fillMode == "fit" ? .fit : .fill)
                        .opacity(override.opacity)
                        .blur(radius: override.blur)
                        .clipped()
                } else if let bgImage = skin.backgroundImage {
                    SkinBackgroundImageView(spec: bgImage)
                }

                // Gradient overlay
                skinGradient
                    .blendMode(colorScheme == .dark ? .plusLighter : .plusDarker)
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
    }
}

extension View {
    func skinTinted(_ skin: SkinDefinition) -> some View {
        modifier(SkinTintModifier(skin: skin))
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

// MARK: - Skin Background Image View

struct SkinBackgroundImageView: View {
    let spec: SkinBackgroundImage

    var body: some View {
        if let nsImage = NSImage(contentsOf: spec.imageURL) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: spec.fillMode == .fill ? .fill : .fit)
                .opacity(spec.opacity)
                .blur(radius: spec.blurRadius)
                .clipped()
        }
    }
}
