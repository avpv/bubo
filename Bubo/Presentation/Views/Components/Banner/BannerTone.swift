import SwiftUI

// MARK: - Banner tone
//
// Shared tone vocabulary for banner-shaped surfaces (capacity notices,
// settings contract sections). Extracted from the deleted `TipBanner`
// component — the tone enum outlived the banner that introduced it.

enum BannerTone {
    case accent
    case success
    case warning
    case destructive
    case quiet

    func color(skin: SkinDefinition) -> Color {
        switch self {
        case .accent:      return skin.accentColor
        case .success:     return skin.resolvedSuccessColor
        case .warning:     return skin.resolvedWarningColor
        case .destructive: return skin.resolvedDestructiveColor
        case .quiet:       return skin.resolvedTextSecondary
        }
    }
}
