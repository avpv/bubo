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

