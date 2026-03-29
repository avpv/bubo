import SwiftUI

// MARK: - Wallpaper Category

enum WallpaperCategory: String, CaseIterable, Identifiable {
    case solidColor
    case gradient
    case pattern
    case live

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .solidColor: "Solid Color"
        case .gradient: "Gradient"
        case .pattern: "Pattern"
        case .live: "Live"
        }
    }

    var systemImage: String {
        switch self {
        case .solidColor: "circle.fill"
        case .gradient: "circle.lefthalf.filled"
        case .pattern: "square.grid.3x3.fill"
        case .live: "waveform.circle.fill"
        }
    }
}

// MARK: - Wallpaper Definition

struct WallpaperDefinition: Identifiable, Equatable {
    let id: String
    let displayName: String
    let category: WallpaperCategory

    /// For solid color wallpapers
    let solidColor: Color?

    /// For gradient wallpapers
    let gradientColors: [Color]
    let gradientStyle: GradientStyle

    /// For pattern wallpapers
    let patternType: PatternType?
    let patternColors: (foreground: Color, background: Color)?

    /// For live wallpapers
    let liveStyle: LiveWallpaperStyle?

    enum GradientStyle: Equatable {
        case none
        case linear(startPoint: UnitPoint, endPoint: UnitPoint)
        case radial(center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat)
        case angular(center: UnitPoint)
    }

    enum PatternType: String, Equatable {
        case dots
        case grid
        case diagonal
        case chevron
        case wave
    }

    enum LiveWallpaperStyle: String, Equatable {
        case aurora
        case particles
        case pulse
        case rain
    }

    static func == (lhs: WallpaperDefinition, rhs: WallpaperDefinition) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Factory Methods

extension WallpaperDefinition {
    static func solid(id: String, name: String, color: Color) -> WallpaperDefinition {
        WallpaperDefinition(
            id: id, displayName: name, category: .solidColor,
            solidColor: color, gradientColors: [], gradientStyle: .none,
            patternType: nil, patternColors: nil, liveStyle: nil
        )
    }

    static func gradient(
        id: String, name: String, colors: [Color],
        style: GradientStyle = .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
    ) -> WallpaperDefinition {
        WallpaperDefinition(
            id: id, displayName: name, category: .gradient,
            solidColor: nil, gradientColors: colors, gradientStyle: style,
            patternType: nil, patternColors: nil, liveStyle: nil
        )
    }

    static func pattern(
        id: String, name: String, type: PatternType,
        foreground: Color, background: Color
    ) -> WallpaperDefinition {
        WallpaperDefinition(
            id: id, displayName: name, category: .pattern,
            solidColor: nil, gradientColors: [], gradientStyle: .none,
            patternType: type, patternColors: (foreground, background), liveStyle: nil
        )
    }

    static func live(id: String, name: String, style: LiveWallpaperStyle) -> WallpaperDefinition {
        WallpaperDefinition(
            id: id, displayName: name, category: .live,
            solidColor: nil, gradientColors: [], gradientStyle: .none,
            patternType: nil, patternColors: nil, liveStyle: style
        )
    }
}

// MARK: - Wallpaper Catalog

enum WallpaperCatalog {
    static let none = WallpaperDefinition.solid(id: "none", name: "None", color: .clear)

    // MARK: Solid Colors
    static let charcoal = WallpaperDefinition.solid(id: "solid_charcoal", name: "Charcoal", color: Color(white: 0.15))
    static let navy = WallpaperDefinition.solid(id: "solid_navy", name: "Navy", color: Color(red: 0.1, green: 0.12, blue: 0.25))
    static let forest = WallpaperDefinition.solid(id: "solid_forest", name: "Forest", color: Color(red: 0.08, green: 0.2, blue: 0.12))
    static let wine = WallpaperDefinition.solid(id: "solid_wine", name: "Wine", color: Color(red: 0.25, green: 0.08, blue: 0.12))
    static let slate = WallpaperDefinition.solid(id: "solid_slate", name: "Slate", color: Color(red: 0.2, green: 0.22, blue: 0.25))
    static let coffee = WallpaperDefinition.solid(id: "solid_coffee", name: "Coffee", color: Color(red: 0.22, green: 0.16, blue: 0.1))

    // MARK: Gradients
    static let sunset = WallpaperDefinition.gradient(
        id: "grad_sunset", name: "Sunset",
        colors: [Color(red: 0.9, green: 0.3, blue: 0.2), Color(red: 0.5, green: 0.1, blue: 0.4)]
    )
    static let ocean = WallpaperDefinition.gradient(
        id: "grad_ocean", name: "Ocean",
        colors: [Color(red: 0.05, green: 0.3, blue: 0.5), Color(red: 0.1, green: 0.15, blue: 0.35)]
    )
    static let aurora = WallpaperDefinition.gradient(
        id: "grad_aurora", name: "Aurora",
        colors: [Color(red: 0.1, green: 0.5, blue: 0.4), Color(red: 0.2, green: 0.1, blue: 0.5)],
        style: .radial(center: .topLeading, startRadius: 0, endRadius: 600)
    )
    static let peach = WallpaperDefinition.gradient(
        id: "grad_peach", name: "Peach",
        colors: [Color(red: 0.95, green: 0.6, blue: 0.4), Color(red: 0.85, green: 0.35, blue: 0.5)]
    )
    static let nightSky = WallpaperDefinition.gradient(
        id: "grad_night_sky", name: "Night Sky",
        colors: [Color(red: 0.05, green: 0.05, blue: 0.15), Color(red: 0.15, green: 0.1, blue: 0.3)],
        style: .linear(startPoint: .bottom, endPoint: .top)
    )
    static let emerald = WallpaperDefinition.gradient(
        id: "grad_emerald", name: "Emerald",
        colors: [Color(red: 0.05, green: 0.35, blue: 0.25), Color(red: 0.1, green: 0.2, blue: 0.15)],
        style: .angular(center: .center)
    )

    // MARK: Patterns
    static let dotGrid = WallpaperDefinition.pattern(
        id: "pat_dots", name: "Dots",
        type: .dots, foreground: Color.white.opacity(0.08), background: Color(white: 0.1)
    )
    static let gridLines = WallpaperDefinition.pattern(
        id: "pat_grid", name: "Grid",
        type: .grid, foreground: Color.white.opacity(0.06), background: Color(white: 0.08)
    )
    static let diagonalStripes = WallpaperDefinition.pattern(
        id: "pat_diagonal", name: "Diagonal",
        type: .diagonal, foreground: Color.cyan.opacity(0.08), background: Color(red: 0.06, green: 0.08, blue: 0.14)
    )
    static let chevrons = WallpaperDefinition.pattern(
        id: "pat_chevron", name: "Chevron",
        type: .chevron, foreground: Color.purple.opacity(0.1), background: Color(red: 0.1, green: 0.06, blue: 0.14)
    )
    static let waves = WallpaperDefinition.pattern(
        id: "pat_wave", name: "Waves",
        type: .wave, foreground: Color.blue.opacity(0.1), background: Color(red: 0.06, green: 0.08, blue: 0.16)
    )

    // MARK: Live
    static let liveAurora = WallpaperDefinition.live(id: "live_aurora", name: "Aurora", style: .aurora)
    static let liveParticles = WallpaperDefinition.live(id: "live_particles", name: "Particles", style: .particles)
    static let livePulse = WallpaperDefinition.live(id: "live_pulse", name: "Pulse", style: .pulse)
    static let liveRain = WallpaperDefinition.live(id: "live_rain", name: "Rain", style: .rain)

    static let allWallpapers: [WallpaperDefinition] = [
        none,
        // Solid
        charcoal, navy, forest, wine, slate, coffee,
        // Gradient
        sunset, ocean, aurora, peach, nightSky, emerald,
        // Pattern
        dotGrid, gridLines, diagonalStripes, chevrons, waves,
        // Live
        liveAurora, liveParticles, livePulse, liveRain,
    ]

    static func wallpaper(forID id: String) -> WallpaperDefinition {
        allWallpapers.first { $0.id == id } ?? none
    }

    static func wallpapers(in category: WallpaperCategory) -> [WallpaperDefinition] {
        allWallpapers.filter { $0.category == category }
    }
}
