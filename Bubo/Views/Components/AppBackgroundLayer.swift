import SwiftUI

enum AppBackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case system
    case accentGlow
    case coolAmbient
    case warmAmbient

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System Default"
        case .accentGlow: return "Accent Glow"
        case .coolAmbient: return "Cool Ambient"
        case .warmAmbient: return "Warm Ambient"
        }
    }
}

struct AppBackgroundLayer: View {
    var style: AppBackgroundStyle
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Group {
            switch style {
            case .system:
                Color.clear
            case .accentGlow:
                RadialGradient(
                    gradient: Gradient(colors: [Color.accentColor.opacity(0.18), .clear]),
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 500
                )
                .blendMode(colorScheme == .dark ? .plusLighter : .plusDarker)
            case .coolAmbient:
                LinearGradient(
                    gradient: Gradient(colors: [Color.indigo.opacity(0.15), Color.blue.opacity(0.05), .clear]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(colorScheme == .dark ? .plusLighter : .plusDarker)
            case .warmAmbient:
                LinearGradient(
                    gradient: Gradient(colors: [Color.orange.opacity(0.15), Color.red.opacity(0.05), .clear]),
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
                .blendMode(colorScheme == .dark ? .plusLighter : .plusDarker)
            }
        }
        .ignoresSafeArea()
    }
}
