import SwiftUI

// MARK: - Wallpaper Background Layer

struct WallpaperBackgroundLayer: View {
    let wallpaper: WallpaperDefinition
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        if wallpaper.id == "none" {
            Color.clear
        } else {
            ZStack {
                switch wallpaper.category {
                case .solidColor:
                    solidView
                case .gradient:
                    gradientView
                case .pattern:
                    patternView
                case .live:
                    liveView
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Solid Color

    @ViewBuilder
    private var solidView: some View {
        if let color = wallpaper.solidColor {
            color.ignoresSafeArea()
        }
    }

    // MARK: - Gradient

    @ViewBuilder
    private var gradientView: some View {
        let colors = wallpaper.gradientColors
        switch wallpaper.gradientStyle {
        case .linear(let start, let end):
            LinearGradient(colors: colors, startPoint: start, endPoint: end)
        case .radial(let center, let startRadius, let endRadius):
            RadialGradient(colors: colors, center: center, startRadius: startRadius, endRadius: endRadius)
        case .angular(let center):
            AngularGradient(colors: colors + [colors.first ?? .clear], center: center)
        case .none:
            if colors.count >= 2 {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    // MARK: - Pattern

    @ViewBuilder
    private var patternView: some View {
        if let patternType = wallpaper.patternType,
           let patternColors = wallpaper.patternColors {
            patternColors.background.ignoresSafeArea()
            Canvas { context, size in
                drawPattern(patternType, in: context, size: size, color: patternColors.foreground)
            }
            .ignoresSafeArea()
        }
    }

    private func drawPattern(_ type: WallpaperDefinition.PatternType, in context: GraphicsContext, size: CGSize, color: Color) {
        let shading = GraphicsContext.Shading.color(color)
        switch type {
        case .dots:
            let spacing: CGFloat = 20
            for x in stride(from: spacing / 2, through: size.width, by: spacing) {
                for y in stride(from: spacing / 2, through: size.height, by: spacing) {
                    let rect = CGRect(x: x - 2, y: y - 2, width: 4, height: 4)
                    context.fill(Circle().path(in: rect), with: shading)
                }
            }
        case .grid:
            let spacing: CGFloat = 24
            for x in stride(from: 0, through: size.width, by: spacing) {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: shading, lineWidth: 0.5)
            }
            for y in stride(from: 0, through: size.height, by: spacing) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: shading, lineWidth: 0.5)
            }
        case .diagonal:
            let spacing: CGFloat = 16
            let total = size.width + size.height
            for offset in stride(from: -size.height, through: total, by: spacing) {
                var path = Path()
                path.move(to: CGPoint(x: offset, y: 0))
                path.addLine(to: CGPoint(x: offset - size.height, y: size.height))
                context.stroke(path, with: shading, lineWidth: 0.5)
            }
        case .chevron:
            let spacing: CGFloat = 20
            let amplitude: CGFloat = 8
            for y in stride(from: 0, through: size.height, by: spacing) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                for x in stride(from: 0, through: size.width, by: amplitude * 2) {
                    path.addLine(to: CGPoint(x: x + amplitude, y: y - amplitude))
                    path.addLine(to: CGPoint(x: x + amplitude * 2, y: y))
                }
                context.stroke(path, with: shading, lineWidth: 0.5)
            }
        case .wave:
            let spacing: CGFloat = 24
            let amplitude: CGFloat = 6
            for y in stride(from: 0, through: size.height, by: spacing) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                for x in stride(from: 0, through: size.width, by: 2) {
                    let yOffset = sin(x * .pi / 30) * amplitude
                    path.addLine(to: CGPoint(x: x, y: y + yOffset))
                }
                context.stroke(path, with: shading, lineWidth: 0.5)
            }
        }
    }

    // MARK: - Live Wallpaper

    @ViewBuilder
    private var liveView: some View {
        if let style = wallpaper.liveStyle {
            switch style {
            case .aurora:
                LiveAuroraView()
            case .particles:
                LiveParticlesView()
            case .pulse:
                LivePulseView()
            case .rain:
                LiveRainView()
            }
        }
    }
}

// MARK: - Live Wallpaper Views

private struct LiveAuroraView: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let w = size.width
                let h = size.height

                // Dark base
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.02, green: 0.04, blue: 0.08)))

                // Aurora bands
                for i in 0..<3 {
                    let fi = CGFloat(i)
                    let yBase = h * (0.2 + fi * 0.15)
                    let hue = (fi * 0.15 + time * 0.02).truncatingRemainder(dividingBy: 1.0)
                    let color = Color(hue: hue, saturation: 0.7, brightness: 0.5).opacity(0.15)

                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: yBase))
                    for x in stride(from: 0, through: w, by: 3) {
                        let y = yBase + sin(x * 0.008 + time * (0.3 + fi * 0.1)) * 30
                            + cos(x * 0.012 + time * 0.2) * 15
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                    path.closeSubpath()
                    context.fill(path, with: .color(color))
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct LiveParticlesView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate

                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.06)))

                for i in 0..<40 {
                    let fi = CGFloat(i)
                    let seed1 = sin(fi * 1.7 + 0.3) * 0.5 + 0.5
                    let seed2 = cos(fi * 2.3 + 1.1) * 0.5 + 0.5
                    let speed = 0.2 + seed1 * 0.3
                    let x = (seed1 * size.width + CGFloat(time * speed * 20)).truncatingRemainder(dividingBy: size.width)
                    let y = (seed2 * size.height + sin(time * speed + fi) * 20)
                        .truncatingRemainder(dividingBy: size.height)
                    let radius = 1.0 + seed2 * 2.0
                    let alpha = 0.15 + seed1 * 0.2
                    let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Circle().path(in: rect), with: .color(Color.white.opacity(alpha)))
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct LivePulseView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.04, green: 0.04, blue: 0.1)))

                for i in 0..<5 {
                    let fi = CGFloat(i)
                    let phase = (time * 0.5 + fi * 0.8).truncatingRemainder(dividingBy: 4.0)
                    let maxRadius = max(size.width, size.height) * 0.5
                    let radius = phase / 4.0 * maxRadius
                    let alpha = (1.0 - phase / 4.0) * 0.12
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    context.stroke(
                        Circle().path(in: rect),
                        with: .color(Color(red: 0.3, green: 0.5, blue: 1.0).opacity(alpha)),
                        lineWidth: 1.5
                    )
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct LiveRainView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate

                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.04, green: 0.06, blue: 0.1)))

                for i in 0..<60 {
                    let fi = CGFloat(i)
                    let seed = sin(fi * 3.7 + 0.5) * 0.5 + 0.5
                    let x = seed * size.width
                    let speed = 80 + seed * 120
                    let y = (CGFloat(time * speed) + fi * 37).truncatingRemainder(dividingBy: size.height + 20) - 10
                    let length = 6 + seed * 10
                    let alpha = 0.08 + seed * 0.12

                    var path = Path()
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x, y: y + length))
                    context.stroke(path, with: .color(Color.cyan.opacity(alpha)), lineWidth: 0.5)
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Wallpaper Preview

struct WallpaperPreviewCard: View {
    let wallpaper: WallpaperDefinition
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(white: 0.12))

                // Preview content
                Group {
                    switch wallpaper.category {
                    case .solidColor:
                        if let color = wallpaper.solidColor {
                            RoundedRectangle(cornerRadius: 6).fill(color)
                        }
                    case .gradient:
                        RoundedRectangle(cornerRadius: 6).fill(previewGradient)
                    case .pattern:
                        if let colors = wallpaper.patternColors {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6).fill(colors.background)
                                Image(systemName: patternIcon)
                                    .font(.system(size: 16))
                                    .foregroundStyle(colors.foreground.opacity(3))
                            }
                        }
                    case .live:
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(livePreviewGradient)
                            Image(systemName: "waveform")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: 40)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                        lineWidth: isSelected ? 2 : 0.5
                    )
            )
            .shadow(
                color: isSelected ? Color.accentColor.opacity(0.3) : .clear,
                radius: isSelected ? 4 : 0
            )

            Text(wallpaper.displayName)
                .font(.caption2)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.primary : .secondary)
                .lineLimit(1)
        }
    }

    private var previewGradient: AnyShapeStyle {
        let colors = wallpaper.gradientColors
        guard colors.count >= 2 else {
            return AnyShapeStyle(colors.first ?? .gray)
        }
        return AnyShapeStyle(
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private var patternIcon: String {
        switch wallpaper.patternType {
        case .dots: "circle.grid.3x3.fill"
        case .grid: "grid"
        case .diagonal: "line.diagonal"
        case .chevron: "chevron.up"
        case .wave: "water.waves"
        case .none: "square.grid.3x3"
        }
    }

    private var livePreviewGradient: AnyShapeStyle {
        switch wallpaper.liveStyle {
        case .aurora:
            AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.1, green: 0.5, blue: 0.4), Color(red: 0.02, green: 0.04, blue: 0.08)],
                startPoint: .top, endPoint: .bottom
            ))
        case .particles:
            AnyShapeStyle(Color(white: 0.08))
        case .pulse:
            AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.15, green: 0.2, blue: 0.4), Color(red: 0.04, green: 0.04, blue: 0.1)],
                startPoint: .center, endPoint: .bottom
            ))
        case .rain:
            AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.1, green: 0.15, blue: 0.25), Color(red: 0.04, green: 0.06, blue: 0.1)],
                startPoint: .top, endPoint: .bottom
            ))
        case .none:
            AnyShapeStyle(Color(white: 0.1))
        }
    }
}
