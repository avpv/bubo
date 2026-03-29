import SwiftUI

// MARK: - Bubo Skin System (Winamp-inspired visual themes)

enum BuboSkin: String, Codable, CaseIterable, Identifiable {
    case classic
    case winampGreen
    case palmBeach
    case toonPop
    case slimDark
    case cyberNeon
    case sunsetRider
    case retroTerminal
    case bubblegum

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .winampGreen: return "Amp Green"
        case .palmBeach: return "Palm Beach"
        case .toonPop: return "Toon Pop"
        case .slimDark: return "Slim Dark"
        case .cyberNeon: return "Cyber Neon"
        case .sunsetRider: return "Sunset Rider"
        case .retroTerminal: return "Retro Terminal"
        case .bubblegum: return "Bubblegum"
        }
    }

    // MARK: - Color Palette

    var accentColor: Color {
        switch self {
        case .classic: return .accentColor
        case .winampGreen: return Color(red: 0.0, green: 0.9, blue: 0.0)
        case .palmBeach: return Color(red: 1.0, green: 0.55, blue: 0.35)
        case .toonPop: return Color(red: 1.0, green: 0.3, blue: 0.3)
        case .slimDark: return Color(red: 0.65, green: 0.5, blue: 0.9)
        case .cyberNeon: return Color(red: 0.0, green: 0.85, blue: 1.0)
        case .sunsetRider: return Color(red: 1.0, green: 0.5, blue: 0.2)
        case .retroTerminal: return Color(red: 0.0, green: 1.0, blue: 0.4)
        case .bubblegum: return Color(red: 1.0, green: 0.4, blue: 0.7)
        }
    }

    var surfaceTint: Color {
        switch self {
        case .classic: return .clear
        case .winampGreen: return Color(red: 0.0, green: 0.15, blue: 0.0)
        case .palmBeach: return Color(red: 0.15, green: 0.08, blue: 0.02)
        case .toonPop: return Color(red: 0.12, green: 0.05, blue: 0.0)
        case .slimDark: return Color(red: 0.08, green: 0.04, blue: 0.15)
        case .cyberNeon: return Color(red: 0.0, green: 0.05, blue: 0.12)
        case .sunsetRider: return Color(red: 0.12, green: 0.05, blue: 0.0)
        case .retroTerminal: return Color(red: 0.0, green: 0.08, blue: 0.02)
        case .bubblegum: return Color(red: 0.12, green: 0.02, blue: 0.08)
        }
    }

    /// Subtle tint applied over surfaces for the skin's mood
    var surfaceTintOpacity: Double {
        self == .classic ? 0 : 0.35
    }

    // MARK: - Background Gradient

    struct GradientSpec {
        let colors: [Color]
        let style: GradientStyle

        enum GradientStyle {
            case linear(startPoint: UnitPoint, endPoint: UnitPoint)
            case radial(center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat)
        }
    }

    var backgroundGradient: GradientSpec {
        switch self {
        case .classic:
            return GradientSpec(colors: [], style: .linear(startPoint: .top, endPoint: .bottom))

        case .winampGreen:
            return GradientSpec(
                colors: [
                    Color(red: 0.0, green: 0.18, blue: 0.0).opacity(0.5),
                    Color(red: 0.0, green: 0.08, blue: 0.0).opacity(0.3),
                    .clear
                ],
                style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
            )

        case .palmBeach:
            return GradientSpec(
                colors: [
                    Color(red: 1.0, green: 0.55, blue: 0.35).opacity(0.18),
                    Color(red: 0.95, green: 0.8, blue: 0.3).opacity(0.10),
                    .clear
                ],
                style: .radial(center: .topTrailing, startRadius: 0, endRadius: 500)
            )

        case .toonPop:
            return GradientSpec(
                colors: [
                    Color(red: 1.0, green: 0.3, blue: 0.2).opacity(0.15),
                    Color(red: 1.0, green: 0.8, blue: 0.0).opacity(0.10),
                    .clear
                ],
                style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
            )

        case .slimDark:
            return GradientSpec(
                colors: [
                    Color(red: 0.3, green: 0.15, blue: 0.5).opacity(0.25),
                    Color(red: 0.15, green: 0.1, blue: 0.25).opacity(0.15),
                    .clear
                ],
                style: .radial(center: .bottomLeading, startRadius: 0, endRadius: 500)
            )

        case .cyberNeon:
            return GradientSpec(
                colors: [
                    Color(red: 0.0, green: 0.4, blue: 0.6).opacity(0.22),
                    Color(red: 0.3, green: 0.0, blue: 0.5).opacity(0.12),
                    .clear
                ],
                style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
            )

        case .sunsetRider:
            return GradientSpec(
                colors: [
                    Color(red: 1.0, green: 0.4, blue: 0.1).opacity(0.20),
                    Color(red: 0.8, green: 0.2, blue: 0.3).opacity(0.10),
                    .clear
                ],
                style: .radial(center: .top, startRadius: 0, endRadius: 450)
            )

        case .retroTerminal:
            return GradientSpec(
                colors: [
                    Color(red: 0.0, green: 0.3, blue: 0.1).opacity(0.25),
                    Color(red: 0.0, green: 0.15, blue: 0.05).opacity(0.15),
                    .clear
                ],
                style: .linear(startPoint: .top, endPoint: .bottom)
            )

        case .bubblegum:
            return GradientSpec(
                colors: [
                    Color(red: 1.0, green: 0.3, blue: 0.6).opacity(0.18),
                    Color(red: 0.7, green: 0.3, blue: 1.0).opacity(0.10),
                    .clear
                ],
                style: .linear(startPoint: .topTrailing, endPoint: .bottomLeading)
            )
        }
    }

    // MARK: - Preview Palette (for skin picker thumbnails)

    var previewColors: [Color] {
        switch self {
        case .classic: return [.gray]
        case .winampGreen: return [Color(red: 0.0, green: 0.7, blue: 0.0), Color(red: 0.1, green: 0.2, blue: 0.1)]
        case .palmBeach: return [Color(red: 1.0, green: 0.55, blue: 0.35), Color(red: 0.95, green: 0.8, blue: 0.3)]
        case .toonPop: return [Color(red: 1.0, green: 0.3, blue: 0.2), Color(red: 1.0, green: 0.8, blue: 0.0)]
        case .slimDark: return [Color(red: 0.3, green: 0.15, blue: 0.5), Color(red: 0.5, green: 0.3, blue: 0.7)]
        case .cyberNeon: return [Color(red: 0.0, green: 0.8, blue: 1.0), Color(red: 0.5, green: 0.0, blue: 0.8)]
        case .sunsetRider: return [Color(red: 1.0, green: 0.5, blue: 0.2), Color(red: 0.8, green: 0.2, blue: 0.3)]
        case .retroTerminal: return [Color(red: 0.0, green: 0.8, blue: 0.3), Color(red: 0.05, green: 0.15, blue: 0.05)]
        case .bubblegum: return [Color(red: 1.0, green: 0.4, blue: 0.7), Color(red: 0.7, green: 0.3, blue: 1.0)]
        }
    }

    var previewGradient: AnyShapeStyle {
        let colors = previewColors
        if colors.count == 1 {
            return AnyShapeStyle(colors[0])
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    /// Accent bar glow color — used for urgency indicators on event rows
    var accentBarGlow: Color {
        accentColor.opacity(0.4)
    }

    /// Whether this skin uses a dark-tinted mood (affects blend modes)
    var prefersDarkTint: Bool {
        switch self {
        case .winampGreen, .slimDark, .cyberNeon, .retroTerminal: return true
        default: return false
        }
    }
}

// MARK: - Skin Background View

struct SkinBackgroundLayer: View {
    let skin: BuboSkin
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        if skin == .classic {
            Color.clear
        } else {
            skinGradient
                .blendMode(colorScheme == .dark ? .plusLighter : .plusDarker)
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

/// Applies the skin's accent tint and surface tint to the view hierarchy.
struct SkinTintModifier: ViewModifier {
    let skin: BuboSkin

    func body(content: Content) -> some View {
        content
            .tint(skin.accentColor)
    }
}

extension View {
    /// Applies skin tinting to the view hierarchy.
    func skinTinted(_ skin: BuboSkin) -> some View {
        modifier(SkinTintModifier(skin: skin))
    }
}

// MARK: - Environment Key

private struct ActiveSkinKey: EnvironmentKey {
    static let defaultValue: BuboSkin = .classic
}

extension EnvironmentValues {
    var activeSkin: BuboSkin {
        get { self[ActiveSkinKey.self] }
        set { self[ActiveSkinKey.self] = newValue }
    }
}
