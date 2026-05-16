import SwiftUI

struct AppBackgroundLayer: View {
    var skin: SkinDefinition = SkinCatalog.defaultSkin
    var wallpaper: WallpaperDefinition = WallpaperCatalog.none
    var customPhotoPath: String = ""
    var customPhotoOpacity: Double = 0.25
    var customPhotoBlur: Double = 2

    /// Vertical parallax offset for the wallpaper layer. Caller threads
    /// the host scroll view's offset through, scaled and clamped so the
    /// wallpaper drifts behind the foreground content as the user scrolls.
    /// The custom photo and skin layers stay fixed — the depth cue comes
    /// from differential motion between wallpaper and content.
    var parallaxY: CGFloat = 0

    /// System Light/Dark appearance — drives the surface-tint blend mode
    /// and tint opacity for `.auto` skins. When the user toggles macOS
    /// system appearance, every `.auto` skin's mood-wash flips with it.
    @Environment(\.colorScheme) private var colorScheme

    /// Whether a non-trivial wallpaper is active (not "none").
    private var hasActiveWallpaper: Bool {
        wallpaper.id != "none"
    }

    var body: some View {
        ZStack {
            // Wallpaper layer (rendered first, behind everything)
            WallpaperBackgroundLayer(wallpaper: wallpaper, parallaxY: parallaxY)

            // User's custom background photo — only when no wallpaper is active
            if !hasActiveWallpaper,
               !customPhotoPath.isEmpty,
               let nsImage = NSImage(contentsOfFile: customPhotoPath) {
                GeometryReader { geo in
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .opacity(customPhotoOpacity)
                .blur(radius: customPhotoBlur)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            }

            // Skin background layer
            SkinBackgroundLayer(skin: skin)

            // Surface tint overlay — derived from the active accent and
            // *effective* mood. `.auto` skins follow the system Light/Dark
            // toggle: light system → plusDarker wash, dark system →
            // plusLighter wash, with opacity scaled per mode.
            if !skin.isClassic {
                let isDark = skin.effectivePrefersDarkTint(in: colorScheme)
                skin.resolvedSurfaceTint
                    .opacity(skin.resolvedSurfaceTintOpacity(in: colorScheme))
                    .blendMode(isDark ? .plusLighter : .plusDarker)
            }
        }
        .ignoresSafeArea()
    }

}
