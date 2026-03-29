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

    // MARK: Solid Colors — Apple-inspired neutral tones
    static let graphiteSolid = WallpaperDefinition.solid(id: "solid_graphite", name: "Graphite", color: Color(red: 0.14, green: 0.14, blue: 0.16))
    static let obsidian = WallpaperDefinition.solid(id: "solid_obsidian", name: "Obsidian", color: Color(red: 0.06, green: 0.06, blue: 0.08))
    static let denim = WallpaperDefinition.solid(id: "solid_denim", name: "Denim", color: Color(red: 0.12, green: 0.16, blue: 0.24))
    static let stone = WallpaperDefinition.solid(id: "solid_stone", name: "Stone", color: Color(red: 0.18, green: 0.16, blue: 0.14))
    static let pewter = WallpaperDefinition.solid(id: "solid_pewter", name: "Pewter", color: Color(red: 0.20, green: 0.20, blue: 0.22))
    static let espresso = WallpaperDefinition.solid(id: "solid_espresso", name: "Espresso", color: Color(red: 0.16, green: 0.10, blue: 0.07))
    static let ink = WallpaperDefinition.solid(id: "solid_ink", name: "Ink", color: Color(red: 0.05, green: 0.06, blue: 0.14))
    static let fog = WallpaperDefinition.solid(id: "solid_fog", name: "Fog", color: Color(red: 0.22, green: 0.22, blue: 0.24))

    // MARK: Gradients — named after macOS releases, refined Apple palette
    static let sequoia = WallpaperDefinition.gradient(
        id: "grad_sequoia", name: "Sequoia",
        colors: [Color(red: 0.48, green: 0.32, blue: 0.18), Color(red: 0.28, green: 0.16, blue: 0.10), Color(red: 0.10, green: 0.06, blue: 0.04)],
        style: .linear(startPoint: .topTrailing, endPoint: .bottomLeading)
    )
    static let monterey = WallpaperDefinition.gradient(
        id: "grad_monterey", name: "Monterey",
        colors: [Color(red: 0.22, green: 0.28, blue: 0.52), Color(red: 0.12, green: 0.14, blue: 0.32), Color(red: 0.04, green: 0.05, blue: 0.12)],
        style: .radial(center: .topLeading, startRadius: 0, endRadius: 500)
    )
    static let sonoma = WallpaperDefinition.gradient(
        id: "grad_sonoma", name: "Sonoma",
        colors: [Color(red: 0.42, green: 0.32, blue: 0.58), Color(red: 0.22, green: 0.16, blue: 0.38), Color(red: 0.08, green: 0.05, blue: 0.14)],
        style: .radial(center: .top, startRadius: 0, endRadius: 480)
    )
    static let ventura = WallpaperDefinition.gradient(
        id: "grad_ventura", name: "Ventura",
        colors: [Color(red: 0.52, green: 0.38, blue: 0.28), Color(red: 0.32, green: 0.18, blue: 0.16), Color(red: 0.12, green: 0.06, blue: 0.06)],
        style: .linear(startPoint: .top, endPoint: .bottom)
    )
    static let bigSur = WallpaperDefinition.gradient(
        id: "grad_big_sur", name: "Big Sur",
        colors: [Color(red: 0.12, green: 0.38, blue: 0.42), Color(red: 0.08, green: 0.22, blue: 0.32), Color(red: 0.04, green: 0.08, blue: 0.14)],
        style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
    )
    static let catalina = WallpaperDefinition.gradient(
        id: "grad_catalina", name: "Catalina",
        colors: [Color(red: 0.08, green: 0.28, blue: 0.48), Color(red: 0.05, green: 0.14, blue: 0.30), Color(red: 0.02, green: 0.06, blue: 0.14)],
        style: .linear(startPoint: .top, endPoint: .bottom)
    )
    static let mojave = WallpaperDefinition.gradient(
        id: "grad_mojave", name: "Mojave",
        colors: [Color(red: 0.42, green: 0.26, blue: 0.16), Color(red: 0.22, green: 0.12, blue: 0.08), Color(red: 0.08, green: 0.04, blue: 0.04)],
        style: .radial(center: .center, startRadius: 0, endRadius: 450)
    )
    static let tahoe = WallpaperDefinition.gradient(
        id: "grad_tahoe", name: "Tahoe",
        colors: [Color(red: 0.18, green: 0.32, blue: 0.42), Color(red: 0.10, green: 0.18, blue: 0.28), Color(red: 0.04, green: 0.06, blue: 0.10)],
        style: .linear(startPoint: .topTrailing, endPoint: .bottomLeading)
    )

    // MARK: Patterns — subtle, texture-only, HIG-compliant
    static let dotGrid = WallpaperDefinition.pattern(
        id: "pat_dots", name: "Dots",
        type: .dots, foreground: Color.white.opacity(0.04), background: Color(red: 0.09, green: 0.09, blue: 0.10)
    )
    static let gridLines = WallpaperDefinition.pattern(
        id: "pat_grid", name: "Grid",
        type: .grid, foreground: Color.white.opacity(0.03), background: Color(red: 0.07, green: 0.07, blue: 0.08)
    )
    static let diagonalStripes = WallpaperDefinition.pattern(
        id: "pat_diagonal", name: "Diagonal",
        type: .diagonal, foreground: Color.white.opacity(0.04), background: Color(red: 0.06, green: 0.07, blue: 0.09)
    )
    static let chevrons = WallpaperDefinition.pattern(
        id: "pat_chevron", name: "Chevron",
        type: .chevron, foreground: Color.white.opacity(0.04), background: Color(red: 0.08, green: 0.07, blue: 0.09)
    )
    static let waves = WallpaperDefinition.pattern(
        id: "pat_wave", name: "Waves",
        type: .wave, foreground: Color.white.opacity(0.04), background: Color(red: 0.06, green: 0.07, blue: 0.09)
    )
    static let honeycomb = WallpaperDefinition.pattern(
        id: "pat_honeycomb", name: "Honeycomb",
        type: .honeycomb, foreground: Color.white.opacity(0.04), background: Color(red: 0.08, green: 0.07, blue: 0.06)
    )
    static let crosshatch = WallpaperDefinition.pattern(
        id: "pat_crosshatch", name: "Crosshatch",
        type: .crosshatch, foreground: Color.white.opacity(0.03), background: Color(red: 0.07, green: 0.07, blue: 0.08)
    )
    static let buboOwl = WallpaperDefinition.pattern(
        id: "pat_bubo", name: "Bubo",
        type: .bubo, foreground: Color.white.opacity(0.04), background: Color(red: 0.07, green: 0.07, blue: 0.09)
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
        graphiteSolid, obsidian, denim, stone, pewter, espresso, ink, fog,
        // Gradient
        sequoia, monterey, sonoma, ventura, bigSur, catalina, mojave, tahoe,
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
