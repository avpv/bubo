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
        case diamonds
        case circles
        case triangles
        case zigzag
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
        case lava
        case snow
        case gradient
        case stars
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

    // MARK: Solid Colors — diverse palette from neutrals to vivid accents
    static let graphite = WallpaperDefinition.solid(id: "solid_graphite", name: "Graphite", color: Color(red: 0.14, green: 0.14, blue: 0.16))
    static let obsidian = WallpaperDefinition.solid(id: "solid_obsidian", name: "Obsidian", color: Color(red: 0.06, green: 0.06, blue: 0.08))
    static let cobalt = WallpaperDefinition.solid(id: "solid_cobalt", name: "Cobalt", color: Color(red: 0.10, green: 0.18, blue: 0.42))
    static let sage = WallpaperDefinition.solid(id: "solid_sage", name: "Sage", color: Color(red: 0.22, green: 0.30, blue: 0.24))
    static let lavender = WallpaperDefinition.solid(id: "solid_lavender", name: "Lavender", color: Color(red: 0.28, green: 0.22, blue: 0.38))
    static let terracotta = WallpaperDefinition.solid(id: "solid_terracotta", name: "Terracotta", color: Color(red: 0.42, green: 0.22, blue: 0.14))
    static let mocha = WallpaperDefinition.solid(id: "solid_mocha", name: "Mocha", color: Color(red: 0.32, green: 0.22, blue: 0.18))
    static let slate = WallpaperDefinition.solid(id: "solid_slate", name: "Slate", color: Color(red: 0.18, green: 0.22, blue: 0.28))
    static let wine = WallpaperDefinition.solid(id: "solid_wine", name: "Wine", color: Color(red: 0.35, green: 0.12, blue: 0.18))
    static let teal = WallpaperDefinition.solid(id: "solid_teal", name: "Teal", color: Color(red: 0.10, green: 0.30, blue: 0.32))
    static let mauve = WallpaperDefinition.solid(id: "solid_mauve", name: "Mauve", color: Color(red: 0.36, green: 0.24, blue: 0.30))
    static let forest = WallpaperDefinition.solid(id: "solid_forest", name: "Forest", color: Color(red: 0.08, green: 0.20, blue: 0.12))

    // MARK: Gradients — vibrant, modern multi-tone
    static let sunset = WallpaperDefinition.gradient(
        id: "grad_sunset", name: "Sunset",
        colors: [Color(red: 0.85, green: 0.35, blue: 0.20), Color(red: 0.65, green: 0.18, blue: 0.30), Color(red: 0.25, green: 0.08, blue: 0.22)],
        style: .linear(startPoint: .top, endPoint: .bottom)
    )
    static let aurora = WallpaperDefinition.gradient(
        id: "grad_aurora", name: "Aurora",
        colors: [Color(red: 0.20, green: 0.75, blue: 0.55), Color(red: 0.15, green: 0.35, blue: 0.65), Color(red: 0.18, green: 0.12, blue: 0.40)],
        style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
    )
    static let peachFuzz = WallpaperDefinition.gradient(
        id: "grad_peach_fuzz", name: "Peach Fuzz",
        colors: [Color(red: 0.92, green: 0.65, blue: 0.48), Color(red: 0.72, green: 0.42, blue: 0.38), Color(red: 0.35, green: 0.18, blue: 0.22)],
        style: .radial(center: .top, startRadius: 0, endRadius: 500)
    )
    static let electricIndigo = WallpaperDefinition.gradient(
        id: "grad_electric_indigo", name: "Electric Indigo",
        colors: [Color(red: 0.35, green: 0.25, blue: 0.85), Color(red: 0.55, green: 0.20, blue: 0.70), Color(red: 0.18, green: 0.08, blue: 0.32)],
        style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
    )
    static let emeraldGlow = WallpaperDefinition.gradient(
        id: "grad_emerald", name: "Emerald",
        colors: [Color(red: 0.12, green: 0.65, blue: 0.42), Color(red: 0.08, green: 0.38, blue: 0.32), Color(red: 0.04, green: 0.15, blue: 0.18)],
        style: .linear(startPoint: .top, endPoint: .bottom)
    )
    static let coralReef = WallpaperDefinition.gradient(
        id: "grad_coral_reef", name: "Coral Reef",
        colors: [Color(red: 0.90, green: 0.45, blue: 0.35), Color(red: 0.65, green: 0.28, blue: 0.45), Color(red: 0.22, green: 0.12, blue: 0.28)],
        style: .radial(center: .topTrailing, startRadius: 0, endRadius: 480)
    )
    static let cyberLime = WallpaperDefinition.gradient(
        id: "grad_cyber_lime", name: "Cyber Lime",
        colors: [Color(red: 0.55, green: 0.85, blue: 0.22), Color(red: 0.18, green: 0.52, blue: 0.28), Color(red: 0.06, green: 0.18, blue: 0.14)],
        style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
    )
    static let roseGold = WallpaperDefinition.gradient(
        id: "grad_rose_gold", name: "Rose Gold",
        colors: [Color(red: 0.82, green: 0.58, blue: 0.52), Color(red: 0.55, green: 0.32, blue: 0.35), Color(red: 0.22, green: 0.12, blue: 0.16)],
        style: .linear(startPoint: .top, endPoint: .bottom)
    )
    static let oceanBreeze = WallpaperDefinition.gradient(
        id: "grad_ocean_breeze", name: "Ocean Breeze",
        colors: [Color(red: 0.18, green: 0.62, blue: 0.78), Color(red: 0.12, green: 0.32, blue: 0.58), Color(red: 0.06, green: 0.12, blue: 0.28)],
        style: .linear(startPoint: .topTrailing, endPoint: .bottomLeading)
    )
    static let butterscotch = WallpaperDefinition.gradient(
        id: "grad_butterscotch", name: "Butterscotch",
        colors: [Color(red: 0.88, green: 0.68, blue: 0.28), Color(red: 0.62, green: 0.38, blue: 0.15), Color(red: 0.25, green: 0.14, blue: 0.08)],
        style: .radial(center: .top, startRadius: 0, endRadius: 450)
    )
    static let digitalLavender = WallpaperDefinition.gradient(
        id: "grad_digital_lavender", name: "Digital Lavender",
        colors: [Color(red: 0.62, green: 0.52, blue: 0.82), Color(red: 0.38, green: 0.28, blue: 0.58), Color(red: 0.14, green: 0.10, blue: 0.24)],
        style: .radial(center: .center, startRadius: 0, endRadius: 450)
    )
    static let neonTokyo = WallpaperDefinition.gradient(
        id: "grad_neon_tokyo", name: "Neon Tokyo",
        colors: [Color(red: 0.90, green: 0.22, blue: 0.55), Color(red: 0.35, green: 0.15, blue: 0.65), Color(red: 0.08, green: 0.06, blue: 0.22)],
        style: .linear(startPoint: .topTrailing, endPoint: .bottomLeading)
    )

    // MARK: Patterns — colorful backgrounds with subtle texture
    static let dotGrid = WallpaperDefinition.pattern(
        id: "pat_dots", name: "Dots",
        type: .dots, foreground: Color.white.opacity(0.06), background: Color(red: 0.12, green: 0.14, blue: 0.22)
    )
    static let gridLines = WallpaperDefinition.pattern(
        id: "pat_grid", name: "Grid",
        type: .grid, foreground: Color.white.opacity(0.05), background: Color(red: 0.08, green: 0.18, blue: 0.16)
    )
    static let diagonalStripes = WallpaperDefinition.pattern(
        id: "pat_diagonal", name: "Diagonal",
        type: .diagonal, foreground: Color.white.opacity(0.05), background: Color(red: 0.22, green: 0.14, blue: 0.24)
    )
    static let chevrons = WallpaperDefinition.pattern(
        id: "pat_chevron", name: "Chevron",
        type: .chevron, foreground: Color(red: 0.85, green: 0.65, blue: 0.35).opacity(0.08), background: Color(red: 0.18, green: 0.14, blue: 0.10)
    )
    static let waves = WallpaperDefinition.pattern(
        id: "pat_wave", name: "Waves",
        type: .wave, foreground: Color(red: 0.35, green: 0.70, blue: 0.85).opacity(0.08), background: Color(red: 0.06, green: 0.12, blue: 0.18)
    )
    static let honeycomb = WallpaperDefinition.pattern(
        id: "pat_honeycomb", name: "Honeycomb",
        type: .honeycomb, foreground: Color(red: 0.85, green: 0.55, blue: 0.25).opacity(0.07), background: Color(red: 0.16, green: 0.12, blue: 0.08)
    )
    static let crosshatch = WallpaperDefinition.pattern(
        id: "pat_crosshatch", name: "Crosshatch",
        type: .crosshatch, foreground: Color(red: 0.65, green: 0.45, blue: 0.70).opacity(0.06), background: Color(red: 0.14, green: 0.10, blue: 0.18)
    )
    static let buboOwl = WallpaperDefinition.pattern(
        id: "pat_bubo", name: "Bubo",
        type: .bubo, foreground: Color(red: 0.45, green: 0.75, blue: 0.55).opacity(0.06), background: Color(red: 0.08, green: 0.14, blue: 0.10)
    )
    static let diamonds = WallpaperDefinition.pattern(
        id: "pat_diamonds", name: "Diamonds",
        type: .diamonds, foreground: Color(red: 0.75, green: 0.55, blue: 0.80).opacity(0.07), background: Color(red: 0.16, green: 0.10, blue: 0.22)
    )
    static let circles = WallpaperDefinition.pattern(
        id: "pat_circles", name: "Circles",
        type: .circles, foreground: Color(red: 0.35, green: 0.65, blue: 0.80).opacity(0.06), background: Color(red: 0.08, green: 0.12, blue: 0.20)
    )
    static let triangles = WallpaperDefinition.pattern(
        id: "pat_triangles", name: "Triangles",
        type: .triangles, foreground: Color(red: 0.85, green: 0.45, blue: 0.35).opacity(0.07), background: Color(red: 0.20, green: 0.10, blue: 0.08)
    )
    static let zigzag = WallpaperDefinition.pattern(
        id: "pat_zigzag", name: "Zigzag",
        type: .zigzag, foreground: Color(red: 0.55, green: 0.80, blue: 0.40).opacity(0.07), background: Color(red: 0.10, green: 0.16, blue: 0.08)
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
    static let liveLava = WallpaperDefinition.live(id: "live_lava", name: "Lava", style: .lava)
    static let liveSnow = WallpaperDefinition.live(id: "live_snow", name: "Snow", style: .snow)
    static let liveGradient = WallpaperDefinition.live(id: "live_gradient", name: "Flow", style: .gradient)
    static let liveStars = WallpaperDefinition.live(id: "live_stars", name: "Stars", style: .stars)

    static let allWallpapers: [WallpaperDefinition] = [
        none,
        // Solid
        graphite, obsidian, cobalt, sage, lavender, terracotta, mocha, slate, wine, teal, mauve, forest,
        // Gradient
        sunset, aurora, peachFuzz, electricIndigo, emeraldGlow, coralReef, cyberLime, roseGold,
        oceanBreeze, butterscotch, digitalLavender, neonTokyo,
        // Pattern
        dotGrid, gridLines, diagonalStripes, chevrons, waves, honeycomb, crosshatch, buboOwl,
        diamonds, circles, triangles, zigzag,
        // Live
        liveAurora, liveParticles, livePulse, liveRain, liveFireflies, liveNebula, liveMatrix, liveRipple,
        liveLava, liveSnow, liveGradient, liveStars,
    ]

    static func wallpaper(forID id: String) -> WallpaperDefinition {
        allWallpapers.first { $0.id == id } ?? none
    }

    static func wallpapers(in category: WallpaperCategory) -> [WallpaperDefinition] {
        allWallpapers.filter { $0.category == category }
    }
}
