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

    /// «Paired with the skin». A sentinel wallpaper that resolves to the
    /// active skin's authored `backgroundGradient`, rendered at full
    /// saturation. The skin's overlay is suppressed in `AppBackgroundLayer`
    /// when this is active — what you see *is* the skin's gravity-of-light,
    /// owning the whole canvas instead of being a 20%-alpha whisper.
    ///
    /// The actual rendering branch lives in `WallpaperBackgroundLayer` —
    /// this definition only carries the id so the picker can show it as
    /// a first-class option alongside concrete wallpapers.
    static let auto = WallpaperDefinition.solid(id: "auto", name: "Auto", color: .clear)

    // MARK: Solid Colors — paper-to-ink ramp + two muted accents.
    // Curated to Apple's restrained palette voice: neutrals first, then
    // a single warm muted accent (sage) and a single cool deep accent
    // (cobalt). No neon, no nostalgia hues — productivity backdrop, not
    // T-shirt swatch.
    static let paper = WallpaperDefinition.solid(id: "solid_paper", name: "Paper", color: Color(red: 0.96, green: 0.95, blue: 0.93))
    static let mist = WallpaperDefinition.solid(id: "solid_mist", name: "Mist", color: Color(red: 0.90, green: 0.91, blue: 0.93))
    static let linen = WallpaperDefinition.solid(id: "solid_linen", name: "Linen", color: Color(red: 0.92, green: 0.88, blue: 0.82))
    static let slate = WallpaperDefinition.solid(id: "solid_slate", name: "Slate", color: Color(red: 0.30, green: 0.35, blue: 0.42))
    static let graphite = WallpaperDefinition.solid(id: "solid_graphite", name: "Graphite", color: Color(red: 0.18, green: 0.18, blue: 0.20))
    static let obsidian = WallpaperDefinition.solid(id: "solid_obsidian", name: "Obsidian", color: Color(red: 0.06, green: 0.06, blue: 0.08))
    static let sage = WallpaperDefinition.solid(id: "solid_sage", name: "Sage", color: Color(red: 0.42, green: 0.56, blue: 0.50))
    static let cobalt = WallpaperDefinition.solid(id: "solid_cobalt", name: "Cobalt", color: Color(red: 0.12, green: 0.22, blue: 0.48))

    // MARK: Gradients — Apple marketing surfaces.
    //
    // Each gradient evokes a specific Apple-aesthetic mood: the macOS
    // desktops (Sequoia, Monterey, Sonoma), Apple Intelligence's muted
    // pastel rainbow, Apple Fitness's coral, the Studio Display radial
    // glow, etc. Restrained saturation throughout — none of the 2024
    // neon-trend gradients here. The legacy `grad_aurora` id is
    // preserved so users who picked it continue to see Aurora.
    static let sequoia = WallpaperDefinition.gradient(
        id: "grad_sequoia", name: "Sequoia",
        colors: [Color(red: 0.97, green: 0.88, blue: 0.82), Color(red: 0.92, green: 0.72, blue: 0.68), Color(red: 0.82, green: 0.55, blue: 0.58)],
        style: .linear(startPoint: .top, endPoint: .bottom)
    )
    static let monterey = WallpaperDefinition.gradient(
        id: "grad_monterey", name: "Monterey",
        colors: [Color(red: 0.30, green: 0.55, blue: 0.78), Color(red: 0.12, green: 0.28, blue: 0.55), Color(red: 0.04, green: 0.10, blue: 0.25)],
        style: .linear(startPoint: .top, endPoint: .bottom)
    )
    static let sonoma = WallpaperDefinition.gradient(
        id: "grad_sonoma", name: "Sonoma",
        colors: [Color(red: 0.46, green: 0.42, blue: 0.68), Color(red: 0.28, green: 0.26, blue: 0.52), Color(red: 0.10, green: 0.10, blue: 0.22)],
        style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
    )
    static let aurora = WallpaperDefinition.gradient(
        id: "grad_aurora", name: "Aurora",
        colors: [Color(red: 0.36, green: 0.78, blue: 0.62), Color(red: 0.18, green: 0.42, blue: 0.68), Color(red: 0.20, green: 0.18, blue: 0.42)],
        style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
    )
    static let marina = WallpaperDefinition.gradient(
        id: "grad_marina", name: "Marina",
        colors: [Color(red: 0.78, green: 0.88, blue: 0.95), Color(red: 0.42, green: 0.62, blue: 0.85), Color(red: 0.20, green: 0.36, blue: 0.62)],
        style: .linear(startPoint: .top, endPoint: .bottom)
    )
    static let fitness = WallpaperDefinition.gradient(
        id: "grad_fitness", name: "Fitness",
        colors: [Color(red: 0.96, green: 0.55, blue: 0.42), Color(red: 0.85, green: 0.28, blue: 0.32), Color(red: 0.42, green: 0.08, blue: 0.18)],
        style: .radial(center: .top, startRadius: 0, endRadius: 480)
    )
    static let intelligence = WallpaperDefinition.gradient(
        id: "grad_intelligence", name: "Intelligence",
        colors: [Color(red: 0.85, green: 0.78, blue: 0.92), Color(red: 0.78, green: 0.88, blue: 0.92), Color(red: 0.95, green: 0.85, blue: 0.82), Color(red: 0.90, green: 0.88, blue: 0.86)],
        style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
    )
    static let studio = WallpaperDefinition.gradient(
        id: "grad_studio", name: "Studio Display",
        colors: [Color(red: 0.85, green: 0.86, blue: 0.88), Color(red: 0.52, green: 0.54, blue: 0.58), Color(red: 0.22, green: 0.22, blue: 0.26)],
        style: .radial(center: .center, startRadius: 0, endRadius: 480)
    )
    static let indigo = WallpaperDefinition.gradient(
        id: "grad_indigo", name: "Indigo",
        colors: [Color(red: 0.38, green: 0.32, blue: 0.68), Color(red: 0.22, green: 0.18, blue: 0.45), Color(red: 0.08, green: 0.06, blue: 0.20)],
        style: .linear(startPoint: .topLeading, endPoint: .bottomTrailing)
    )
    static let roseGold = WallpaperDefinition.gradient(
        id: "grad_rose_gold", name: "Rose Gold",
        colors: [Color(red: 0.96, green: 0.78, blue: 0.72), Color(red: 0.82, green: 0.55, blue: 0.52), Color(red: 0.42, green: 0.22, blue: 0.26)],
        style: .linear(startPoint: .top, endPoint: .bottom)
    )

    // MARK: Patterns — architectural, restrained, max 0.04 foreground alpha.
    //
    // Apple's own marketing surfaces use almost no decorative patterns;
    // a productivity backdrop is the exception where a faint geometric
    // texture adds quietness without competing with content. All six
    // ride a near-neutral background (slate / graphite tones) so they
    // don't bring their own colour story — that's the skin's job.
    //
    // Six patterns retired from the catalog (`chevron`, `diagonal`,
    // `honeycomb`, `diamonds`, `triangles`, `zigzag`) — their enum cases
    // and renderer branches stay in the codebase so any pre-existing
    // user persistence still resolves to *something*, but they no
    // longer surface in the picker.
    static let dotGrid = WallpaperDefinition.pattern(
        id: "pat_dots", name: "Dots",
        type: .dots, foreground: Color.white.opacity(0.04), background: Color(red: 0.10, green: 0.12, blue: 0.16)
    )
    static let gridLines = WallpaperDefinition.pattern(
        id: "pat_grid", name: "Grid",
        type: .grid, foreground: Color.white.opacity(0.04), background: Color(red: 0.10, green: 0.12, blue: 0.14)
    )
    static let waves = WallpaperDefinition.pattern(
        id: "pat_wave", name: "Horizon",
        type: .wave, foreground: Color.white.opacity(0.04), background: Color(red: 0.06, green: 0.10, blue: 0.16)
    )
    static let crosshatch = WallpaperDefinition.pattern(
        id: "pat_crosshatch", name: "Mesh",
        type: .crosshatch, foreground: Color.white.opacity(0.035), background: Color(red: 0.10, green: 0.10, blue: 0.12)
    )
    static let circles = WallpaperDefinition.pattern(
        id: "pat_circles", name: "Contour",
        type: .circles, foreground: Color.white.opacity(0.04), background: Color(red: 0.08, green: 0.10, blue: 0.14)
    )
    static let buboOwl = WallpaperDefinition.pattern(
        id: "pat_bubo", name: "Bubo",
        type: .bubo, foreground: Color.white.opacity(0.04), background: Color(red: 0.08, green: 0.12, blue: 0.10)
    )

    // MARK: Live — Apple-ambient motion only.
    //
    // Curated to six wallpapers whose motion vocabulary reads as
    // *productivity-safe ambience* — quiet halos, slow drifts, gentle
    // ripples. Six retired from the catalog (`particles`, `rain`,
    // `fireflies`, `matrix`, `lava`, `snow`) — their `LiveXxxView` swift
    // types stay in the codebase so any pre-existing user persistence
    // still resolves, but they no longer surface in the picker.
    static let liveAurora = WallpaperDefinition.live(id: "live_aurora", name: "Aurora", style: .aurora)
    static let livePulse = WallpaperDefinition.live(id: "live_pulse", name: "Pulse", style: .pulse)
    static let liveNebula = WallpaperDefinition.live(id: "live_nebula", name: "Nebula", style: .nebula)
    static let liveRipple = WallpaperDefinition.live(id: "live_ripple", name: "Ripple", style: .ripple)
    static let liveGradient = WallpaperDefinition.live(id: "live_gradient", name: "Flow", style: .gradient)
    static let liveStars = WallpaperDefinition.live(id: "live_stars", name: "Stars", style: .stars)

    static let allWallpapers: [WallpaperDefinition] = [
        none, auto,
        // Solid — paper-to-ink ramp + 2 muted accents
        paper, mist, linen, slate, graphite, obsidian, sage, cobalt,
        // Gradient — Apple marketing surfaces
        sequoia, monterey, sonoma, aurora, marina, fitness, intelligence, studio, indigo, roseGold,
        // Pattern — architectural, restrained
        dotGrid, gridLines, waves, crosshatch, circles, buboOwl,
        // Live — Apple-ambient motion
        liveAurora, livePulse, liveNebula, liveRipple, liveGradient, liveStars,
    ]

    /// Retired ids that should fall through to the skin-paired backdrop
    /// instead of silently disappearing as `.none`. Two scenarios:
    /// (1) the previous catalog had a wallpaper the user picked, and we
    /// dropped it in this curation pass; (2) the user is on a fresh
    /// install and there's no persisted id at all. Either way, `auto`
    /// is the right default.
    static func wallpaper(forID id: String) -> WallpaperDefinition {
        allWallpapers.first { $0.id == id } ?? auto
    }

    static func wallpapers(in category: WallpaperCategory) -> [WallpaperDefinition] {
        allWallpapers.filter { $0.category == category }
    }
}
