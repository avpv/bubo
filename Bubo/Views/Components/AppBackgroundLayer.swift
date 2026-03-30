import SwiftUI

struct AppBackgroundLayer: View {
    var skin: SkinDefinition = SkinCatalog.defaultSkin
    var wallpaper: WallpaperDefinition = WallpaperCatalog.none
    var customPhotoPath: String = ""
    var customPhotoOpacity: Double = 0.25
    var customPhotoBlur: Double = 2
    var skinImageOverride: SkinImageOverride? = nil
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            // Wallpaper layer (rendered first, behind everything)
            WallpaperBackgroundLayer(wallpaper: wallpaper)

            // User's custom background photo
            if !customPhotoPath.isEmpty,
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
            }

            // Skin background layer
            SkinBackgroundLayer(skin: skin, skinImageOverride: skinImageOverride)

            // Surface tint overlay
            if !skin.isClassic {
                skin.surfaceTint
                    .opacity(skin.surfaceTintOpacity)
                    .blendMode(colorScheme == .dark ? .plusLighter : .plusDarker)
            }
        }
        .ignoresSafeArea()
    }

}
