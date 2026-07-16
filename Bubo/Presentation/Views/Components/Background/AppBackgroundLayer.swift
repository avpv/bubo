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
            // Wallpaper layer (rendered first, behind everything). When
            // wallpaper is "auto", this layer borrows the active skin's
            // backgroundGradient as the full-canvas backdrop.
            WallpaperBackgroundLayer(wallpaper: wallpaper, skin: skin, parallaxY: parallaxY)

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

            // Legibility scrim — a faint neutral wash that pushes a
            // mid-luminance wallpaper toward its foreground pole so
            // labels clear contrast (see BackdropLegibility.swift).
            // Clearly light or dark canvases get no scrim at all.
            if hasActiveWallpaper, let scrim = wallpaper.legibilityScrim(for: skin) {
                scrim.color.opacity(scrim.opacity)
            }

            // Skin background layer — only when no wallpaper is active.
            // A wallpaper owns the canvas: layering the skin's gradient
            // on top double-washes it (blue skin over blue wallpaper
            // drowned the content before this gate). In auto-backdrop
            // mode the wallpaper layer already paints the same gradient
            // at full saturation.
            if !hasActiveWallpaper {
                SkinBackgroundLayer(skin: skin)
            }

            // Surface tint overlay — derived from the active accent and
            // *effective* mood. `.auto` skins follow the system Light/Dark
            // toggle: light system → plusDarker wash, dark system →
            // plusLighter wash, with opacity scaled per mode.
            //
            // Skin-canvas only (DESIGN_REVIEW R3): when a wallpaper owns
            // the canvas the wash is skipped entirely — the previous
            // damped (×0.4) accent tint still pushed every wallpaper
            // toward the accent hue, feeding the monochrome collapse on
            // same-hue wallpapers. The canvas carries its own colour
            // story; chrome stays neutral over it.
            if !skin.isClassic && !hasActiveWallpaper {
                let isDark = skin.effectivePrefersDarkTint(in: colorScheme)
                skin.resolvedSurfaceTint
                    .opacity(skin.resolvedSurfaceTintOpacity(in: colorScheme))
                    .blendMode(isDark ? .plusLighter : .plusDarker)
            }
        }
        .ignoresSafeArea()
    }

}
