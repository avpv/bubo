import Foundation

// MARK: - ReminderSettings → Wallpaper bridge

/// Resolves the persisted wallpaper ID stored on `ReminderSettings` to a
/// fully-realised `WallpaperDefinition` from the presentation-side
/// catalog. Kept in `Presentation/` so `Domain/ReminderSettings.swift`
/// doesn't have to know about SwiftUI-backed types.
extension ReminderSettings {
    var selectedWallpaper: WallpaperDefinition {
        WallpaperCatalog.wallpaper(forID: selectedWallpaperID)
    }
}
