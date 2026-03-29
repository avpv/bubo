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
        case honeycomb
        case crosshatch
        case bubo
    }

    enum LiveWallpaperStyle: String, Equatable {
        case aurora
        case particles
        case pulse
        case rain
        case fireflies
        case nebula
        case matrix
        case ripple
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
    static let charcoal = WallpaperDefinition.solid(id: "solid_charcoal", name: "Charcoal", color: Color(red: 0.13, green: 0.13, blue: 0.15))
    static let navy = WallpaperDefinition.solid(id: "solid_navy", name: "Navy", color: Color(red: 0.08, green: 0.1, blue: 0.28))
    static let forest = WallpaperDefinition.solid(id: "solid_forest", name: "Forest", color: Color(red: 0.06, green: 0.22, blue: 0.18))
    static let wine = WallpaperDefinition.solid(id: "solid_wine", name: "Wine", color: Color(red: 0.32, green: 0.06, blue: 0.14))
    static let slate = WallpaperDefinition.solid(id: "solid_slate", name: "Slate", color: Color(red: 0.16, green: 0.2, blue: 0.26))
    static let coffee = WallpaperDefinition.solid(id: "solid_coffee", name: "Coffee", color: Color(red: 0.24, green: 0.16, blue: 0.1))
    static let plum = WallpaperDefinition.solid(id: "solid_plum", name: "Plum", color: Color(red: 0.24, green: 0.08, blue: 0.3))
    static let midnight = WallpaperDefinition.solid(id: "solid_midnight", name: "Midnight", color: Color(red: 0.04, green: 0.04, blue: 0.14))

    // MARK: Gradients
    static let sunset = WallpaperDefinition.gradient(
        id: "grad_sunset", name: "Sunset",
        colors: [Color(red: 0.95, green: 0.45, blue: 0.25), Color(red: 0.75, green: 0.15, blue: 0.35), Color(red: 0.3, green: 0.08, blue: 0.25)],
        style: .linear(startPoint: .topTrailing, endPoint: .bottomLeading)
    )
    static let ocean = WallpaperDefinition.gradient(
        id: "grad_ocean", name: "Ocean",
        colors: [Color(red: 0.0, green: 0.45, blue: 0.65), Color(red: 0.05, green: 0.2, blue: 0.5), Color(red: 0.04, green: 0.08, blue: 0.22)],
        style: .linear(startPoint: .top, endPoint: .bottom)
    )
    static let aurora = WallpaperDefinition.gradient(
        id: "grad_aurora", name: "Aurora",
        colors: [Color(red: 0.15, green: 0.65, blue: 0.55), Color(red: 0.25, green: 0.2, blue: 0.6), Color(red: 0.08, green: 0.05, blue: 0.2)],
        style: .radial(center: .topLeading, startRadius: 0, endRadius: 500)
    )
    static let peach = WallpaperDefinition.gradient(
        id: "grad_peach", name: "Peach",
        colors: [Color(red: 1.0, green: 0.7, blue: 0.5), Color(red: 0.9, green: 0.4, blue: 0.5), Color(red: 0.4, green: 0.15, blue: 0.3)],
        style: .radial(center: .top, startRadius: 0, endRadius: 450)
    )
    static let nightSky = WallpaperDefinition.gradient(
        id: "grad_night_sky", name: "Night Sky",
        colors: [Color(red: 0.12, green: 0.1, blue: 0.3), Color(red: 0.05, green: 0.04, blue: 0.14), Color(red: 0.02, green: 0.02, blue: 0.06)],
        style: .linear(startPoint: .top, endPoint: .bottom)
    )
    static let emerald = WallpaperDefinition.gradient(
        id: "grad_emerald", name: "Emerald",
        colors: [Color(red: 0.1, green: 0.55, blue: 0.4), Color(red: 0.05, green: 0.3, blue: 0.35), Color(red: 0.03, green: 0.1, blue: 0.12)],
        style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
    )
    static let lavender = WallpaperDefinition.gradient(
        id: "grad_lavender", name: "Lavender",
        colors: [Color(red: 0.55, green: 0.4, blue: 0.8), Color(red: 0.3, green: 0.2, blue: 0.55), Color(red: 0.1, green: 0.06, blue: 0.2)],
        style: .radial(center: .center, startRadius: 0, endRadius: 400)
    )
    static let autumn = WallpaperDefinition.gradient(
        id: "grad_autumn", name: "Autumn",
        colors: [Color(red: 0.85, green: 0.5, blue: 0.15), Color(red: 0.6, green: 0.2, blue: 0.15), Color(red: 0.2, green: 0.08, blue: 0.08)],
        style: .linear(startPoint: .topTrailing, endPoint: .bottomLeading)
    )

    // MARK: Patterns
    static let dotGrid = WallpaperDefinition.pattern(
        id: "pat_dots", name: "Dots",
        type: .dots, foreground: Color.white.opacity(0.06), background: Color(red: 0.08, green: 0.08, blue: 0.1)
    )
    static let gridLines = WallpaperDefinition.pattern(
        id: "pat_grid", name: "Grid",
        type: .grid, foreground: Color.white.opacity(0.04), background: Color(red: 0.06, green: 0.06, blue: 0.08)
    )
    static let diagonalStripes = WallpaperDefinition.pattern(
        id: "pat_diagonal", name: "Diagonal",
        type: .diagonal, foreground: Color(red: 0.3, green: 0.6, blue: 0.8).opacity(0.06), background: Color(red: 0.05, green: 0.06, blue: 0.1)
    )
    static let chevrons = WallpaperDefinition.pattern(
        id: "pat_chevron", name: "Chevron",
        type: .chevron, foreground: Color(red: 0.6, green: 0.4, blue: 0.8).opacity(0.07), background: Color(red: 0.07, green: 0.05, blue: 0.1)
    )
    static let waves = WallpaperDefinition.pattern(
        id: "pat_wave", name: "Waves",
        type: .wave, foreground: Color(red: 0.2, green: 0.5, blue: 0.7).opacity(0.07), background: Color(red: 0.04, green: 0.06, blue: 0.1)
    )
    static let honeycomb = WallpaperDefinition.pattern(
        id: "pat_honeycomb", name: "Honeycomb",
        type: .honeycomb, foreground: Color(red: 0.9, green: 0.6, blue: 0.2).opacity(0.06), background: Color(red: 0.08, green: 0.06, blue: 0.04)
    )
    static let crosshatch = WallpaperDefinition.pattern(
        id: "pat_crosshatch", name: "Crosshatch",
        type: .crosshatch, foreground: Color.white.opacity(0.04), background: Color(red: 0.07, green: 0.07, blue: 0.08)
    )
    static let buboOwl = WallpaperDefinition.pattern(
        id: "pat_bubo", name: "Bubo",
        type: .bubo, foreground: Color.white.opacity(0.05), background: Color(red: 0.06, green: 0.06, blue: 0.09)
    )

    // MARK: Live
    static let liveAurora = WallpaperDefinition.live(id: "live_aurora", name: "Aurora", style: .aurora)
    static let liveParticles = WallpaperDefinition.live(id: "live_particles", name: "Particles", style: .particles)
    static let livePulse = WallpaperDefinition.live(id: "live_pulse", name: "Pulse", style: .pulse)
    static let liveRain = WallpaperDefinition.live(id: "live_rain", name: "Rain", style: .rain)
    static let liveFireflies = WallpaperDefinition.live(id: "live_fireflies", name: "Fireflies", style: .fireflies)
    static let liveNebula = WallpaperDefinition.live(id: "live_nebula", name: "Nebula", style: .nebula)
    static let liveMatrix = WallpaperDefinition.live(id: "live_matrix", name: "Matrix", style: .matrix)
    static let liveRipple = WallpaperDefinition.live(id: "live_ripple", name: "Ripple", style: .ripple)

    static let allWallpapers: [WallpaperDefinition] = [
        none,
        // Solid
        charcoal, navy, forest, wine, slate, coffee, plum, midnight,
        // Gradient
        sunset, ocean, aurora, peach, nightSky, emerald, lavender, autumn,
        // Pattern
        dotGrid, gridLines, diagonalStripes, chevrons, waves, honeycomb, crosshatch, buboOwl,
        // Live
        liveAurora, liveParticles, livePulse, liveRain, liveFireflies, liveNebula, liveMatrix, liveRipple,
    ]

    static func wallpaper(forID id: String) -> WallpaperDefinition {
        allWallpapers.first { $0.id == id } ?? none
    }

    static func wallpapers(in category: WallpaperCategory) -> [WallpaperDefinition] {
        allWallpapers.filter { $0.category == category }
    }
}
