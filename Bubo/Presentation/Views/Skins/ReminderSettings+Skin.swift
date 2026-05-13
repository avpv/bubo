import Foundation
import BuboDomain

// MARK: - ReminderSettings → Skin bridge

/// Resolves the persisted skin ID stored on `ReminderSettings` to a
/// fully-realised `SkinDefinition` from the presentation-side catalog.
/// Kept in `Presentation/` so `Sources/Domain/Reminders/ReminderSettings.swift`
/// doesn't have to know about the SwiftUI-backed `SkinCatalog`.
extension ReminderSettings {
    var selectedSkin: SkinDefinition {
        SkinCatalog.skin(forID: selectedSkinID)
    }
}
