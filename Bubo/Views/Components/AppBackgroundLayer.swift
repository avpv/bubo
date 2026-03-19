import SwiftUI

enum AppBackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case system
    case accentGlow
    case coolAmbient
    case warmAmbient
    case mintBreeze
    case midnightPurple
    case blushPink
    case oceanDepth
    case goldenHour

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System Default"
        case .accentGlow: return "Accent Glow"
        case .coolAmbient: return "Cool Ambient"
        case .warmAmbient: return "Warm Ambient"
        case .mintBreeze: return "Mint Breeze"
        case .midnightPurple: return "Midnight Purple"
        case .blushPink: return "Blush Pink"
        case .oceanDepth: return "Ocean Depth"
        case .goldenHour: return "Golden Hour"
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
            case .mintBreeze:
                LinearGradient(
                    gradient: Gradient(colors: [Color.mint.opacity(0.15), Color.teal.opacity(0.05), .clear]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(colorScheme == .dark ? .plusLighter : .plusDarker)
            case .midnightPurple:
                RadialGradient(
                    gradient: Gradient(colors: [Color.purple.opacity(0.15), Color.indigo.opacity(0.05), .clear]),
                    center: .bottomLeading,
                    startRadius: 0,
                    endRadius: 500
                )
                .blendMode(colorScheme == .dark ? .plusLighter : .plusDarker)
            case .blushPink:
                LinearGradient(
                    gradient: Gradient(colors: [Color.pink.opacity(0.15), Color.orange.opacity(0.05), .clear]),
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
                .blendMode(colorScheme == .dark ? .plusLighter : .plusDarker)
            case .oceanDepth:
                LinearGradient(
                    gradient: Gradient(colors: [Color.cyan.opacity(0.15), Color.blue.opacity(0.08), .clear]),
                    startPoint: .bottomTrailing,
                    endPoint: .topLeading
                )
                .blendMode(colorScheme == .dark ? .plusLighter : .plusDarker)
            case .goldenHour:
                RadialGradient(
                    gradient: Gradient(colors: [Color.yellow.opacity(0.15), Color.orange.opacity(0.08), .clear]),
                    center: .top,
                    startRadius: 0,
                    endRadius: 400
                )
                .blendMode(colorScheme == .dark ? .plusLighter : .plusDarker)
            }
        }
        .ignoresSafeArea()
    }
}
