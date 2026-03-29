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
            let spacing: CGFloat = 28
            for row in 0..<Int(size.height / spacing + 1) {
                let isOffset = row % 2 == 1
                for x in stride(from: (isOffset ? spacing / 2 : 0), through: size.width, by: spacing) {
                    let y = CGFloat(row) * spacing
                    let r: CGFloat = 1.8
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    context.fill(Circle().path(in: rect), with: shading)
                }
            }
        case .grid:
            let spacing: CGFloat = 32
            for x in stride(from: 0, through: size.width, by: spacing) {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: shading, lineWidth: 0.35)
            }
            for y in stride(from: 0, through: size.height, by: spacing) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: shading, lineWidth: 0.35)
            }
        case .diagonal:
            let spacing: CGFloat = 22
            let total = size.width + size.height
            for offset in stride(from: -size.height, through: total, by: spacing) {
                var path = Path()
                path.move(to: CGPoint(x: offset, y: 0))
                path.addLine(to: CGPoint(x: offset - size.height, y: size.height))
                context.stroke(path, with: shading, lineWidth: 0.35)
            }
        case .chevron:
            let spacing: CGFloat = 28
            let amplitude: CGFloat = 10
            for y in stride(from: 0, through: size.height, by: spacing) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                for x in stride(from: 0, through: size.width, by: amplitude * 2) {
                    path.addLine(to: CGPoint(x: x + amplitude, y: y - amplitude))
                    path.addLine(to: CGPoint(x: x + amplitude * 2, y: y))
                }
                context.stroke(path, with: shading, lineWidth: 0.4)
            }
        case .wave:
            let spacing: CGFloat = 30
            let amplitude: CGFloat = 8
            for y in stride(from: 0, through: size.height, by: spacing) {
                var path = Path()
                path.move(to: CGPoint(x: -10, y: y))
                for x in stride(from: -10, through: size.width + 10, by: 1) {
                    let yOffset = sin(x * .pi / 40) * amplitude
                    path.addLine(to: CGPoint(x: x, y: y + yOffset))
                }
                context.stroke(path, with: shading, lineWidth: 0.4)
            }
        case .honeycomb:
            let hexRadius: CGFloat = 18
            let hexWidth = hexRadius * 2
            let hexHeight = hexRadius * sqrt(3)
            for row in 0..<Int(size.height / hexHeight + 2) {
                for col in 0..<Int(size.width / hexWidth + 2) {
                    let offsetX = (row % 2 == 0) ? 0 : hexRadius
                    let cx = CGFloat(col) * hexWidth + offsetX
                    let cy = CGFloat(row) * hexHeight
                    var path = Path()
                    for i in 0..<6 {
                        let angle = CGFloat(i) * .pi / 3 - .pi / 6
                        let px = cx + hexRadius * cos(angle)
                        let py = cy + hexRadius * sin(angle)
                        if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
                        else { path.addLine(to: CGPoint(x: px, y: py)) }
                    }
                    path.closeSubpath()
                    context.stroke(path, with: shading, lineWidth: 0.35)
                }
            }
        case .crosshatch:
            let spacing: CGFloat = 22
            let total = size.width + size.height
            for offset in stride(from: -size.height, through: total, by: spacing) {
                var path1 = Path()
                path1.move(to: CGPoint(x: offset, y: 0))
                path1.addLine(to: CGPoint(x: offset - size.height, y: size.height))
                context.stroke(path1, with: shading, lineWidth: 0.3)
                var path2 = Path()
                path2.move(to: CGPoint(x: offset, y: 0))
                path2.addLine(to: CGPoint(x: offset + size.height, y: size.height))
                context.stroke(path2, with: shading, lineWidth: 0.3)
            }
        case .bubo:
            let cellSize: CGFloat = 56
            for row in stride(from: 0, through: size.height, by: cellSize) {
                for col in stride(from: 0, through: size.width, by: cellSize) {
                    let isOffset = Int(row / cellSize) % 2 == 1
                    let cx = col + (isOffset ? cellSize / 2 : 0) + cellSize / 2
                    let cy = row + cellSize / 2

                    // Head — rounded silhouette
                    let headR: CGFloat = 16
                    let headRect = CGRect(x: cx - headR, y: cy - headR, width: headR * 2, height: headR * 2)
                    context.stroke(Circle().path(in: headRect), with: shading, lineWidth: 0.4)

                    // Ear tufts — simple strokes
                    var leftEar = Path()
                    leftEar.move(to: CGPoint(x: cx - 10, y: cy - 13))
                    leftEar.addLine(to: CGPoint(x: cx - 14, y: cy - 22))
                    context.stroke(leftEar, with: shading, lineWidth: 0.4)

                    var rightEar = Path()
                    rightEar.move(to: CGPoint(x: cx + 10, y: cy - 13))
                    rightEar.addLine(to: CGPoint(x: cx + 14, y: cy - 22))
                    context.stroke(rightEar, with: shading, lineWidth: 0.4)

                    // Eyes — circles
                    let eyeR: CGFloat = 5
                    let eyeY = cy - 2
                    let leftEyeRect = CGRect(x: cx - 7 - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2)
                    let rightEyeRect = CGRect(x: cx + 7 - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2)
                    context.stroke(Circle().path(in: leftEyeRect), with: shading, lineWidth: 0.35)
                    context.stroke(Circle().path(in: rightEyeRect), with: shading, lineWidth: 0.35)

                    // Pupils
                    let pupilR: CGFloat = 1.8
                    context.fill(Circle().path(in: CGRect(x: cx - 7 - pupilR, y: eyeY - pupilR, width: pupilR * 2, height: pupilR * 2)), with: shading)
                    context.fill(Circle().path(in: CGRect(x: cx + 7 - pupilR, y: eyeY - pupilR, width: pupilR * 2, height: pupilR * 2)), with: shading)

                    // Beak — minimal V
                    var beak = Path()
                    beak.move(to: CGPoint(x: cx - 2, y: cy + 4))
                    beak.addLine(to: CGPoint(x: cx, y: cy + 8))
                    beak.addLine(to: CGPoint(x: cx + 2, y: cy + 4))
                    context.stroke(beak, with: shading, lineWidth: 0.35)
                }
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
            case .fireflies:
                LiveFirefliesView()
            case .nebula:
                LiveNebulaView()
            case .matrix:
                LiveMatrixView()
            case .ripple:
                LiveRippleView()
            }
        }
    }
}

// MARK: - Live Wallpaper Views

private struct LiveAuroraView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let w = size.width
                let h = size.height

                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.01, green: 0.02, blue: 0.06)))

                // Soft fluid aurora blobs
                for i in 0..<5 {
                    let fi = CGFloat(i)
                    let xCenter = w * (0.15 + fi * 0.18) + sin(time * 0.08 + fi * 1.2) * w * 0.1
                    let yCenter = h * (0.15 + fi * 0.08) + cos(time * 0.06 + fi * 0.9) * h * 0.08
                    let radius = min(w, h) * (0.25 + fi * 0.05)
                    let hue = (0.45 + fi * 0.08 + time * 0.008).truncatingRemainder(dividingBy: 1.0)
                    let rect = CGRect(x: xCenter - radius, y: yCenter - radius, width: radius * 2, height: radius * 2)
                    context.fill(
                        Circle().path(in: rect),
                        with: .color(Color(hue: hue, saturation: 0.65, brightness: 0.55).opacity(0.06))
                    )
                }

                // Aurora ribbons
                for i in 0..<3 {
                    let fi = CGFloat(i)
                    let yBase = h * (0.2 + fi * 0.12)
                    let hue = (0.4 + fi * 0.12 + time * 0.012).truncatingRemainder(dividingBy: 1.0)

                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: yBase))
                    for x in stride(from: 0, through: w, by: 2) {
                        let y = yBase
                            + sin(x * 0.006 + time * (0.15 + fi * 0.05)) * 35
                            + cos(x * 0.01 + time * 0.1 + fi) * 20
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: w, y: yBase + 60))
                    path.addLine(to: CGPoint(x: 0, y: yBase + 60))
                    path.closeSubpath()
                    context.fill(path, with: .color(Color(hue: hue, saturation: 0.6, brightness: 0.5).opacity(0.08)))
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

                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.04, green: 0.04, blue: 0.06)))

                // Soft ambient glow spots
                for i in 0..<3 {
                    let fi = CGFloat(i)
                    let cx = size.width * (0.25 + fi * 0.25) + sin(time * 0.05 + fi * 2) * 30
                    let cy = size.height * (0.3 + fi * 0.15) + cos(time * 0.04 + fi) * 20
                    let r = min(size.width, size.height) * 0.3
                    let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                    let hue = (fi * 0.3 + time * 0.005).truncatingRemainder(dividingBy: 1.0)
                    context.fill(Circle().path(in: rect), with: .color(Color(hue: hue, saturation: 0.3, brightness: 0.3).opacity(0.04)))
                }

                // Floating particles
                for i in 0..<30 {
                    let fi = CGFloat(i)
                    let seed1 = sin(fi * 1.7 + 0.3) * 0.5 + 0.5
                    let seed2 = cos(fi * 2.3 + 1.1) * 0.5 + 0.5
                    let speed = 0.1 + seed1 * 0.15
                    let x = seed1 * size.width + sin(time * speed * 0.8 + fi * 0.5) * 40
                    let y = (seed2 * size.height + CGFloat(time * speed * 8)).truncatingRemainder(dividingBy: size.height)
                    let radius = 1.0 + seed2 * 1.5
                    let alpha = 0.1 + seed1 * 0.15
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
                let center = CGPoint(x: size.width / 2, y: size.height * 0.45)

                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.03, green: 0.03, blue: 0.08)))

                // Central glow
                let glowR = min(size.width, size.height) * 0.25
                let glowPulse = 0.03 + sin(time * 0.4) * 0.015
                let glowRect = CGRect(x: center.x - glowR, y: center.y - glowR, width: glowR * 2, height: glowR * 2)
                context.fill(Circle().path(in: glowRect), with: .color(Color(red: 0.2, green: 0.35, blue: 0.9).opacity(glowPulse)))

                // Expanding rings
                for i in 0..<6 {
                    let fi = CGFloat(i)
                    let phase = (time * 0.35 + fi * 0.9).truncatingRemainder(dividingBy: 5.5)
                    let maxRadius = max(size.width, size.height) * 0.45
                    let radius = phase / 5.5 * maxRadius
                    let alpha = (1.0 - phase / 5.5) * 0.08
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    context.stroke(
                        Circle().path(in: rect),
                        with: .color(Color(red: 0.35, green: 0.5, blue: 1.0).opacity(alpha)),
                        lineWidth: 1.0
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

                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.03, green: 0.04, blue: 0.08)))

                // Soft ambient light
                let glowR = size.width * 0.4
                let glowRect = CGRect(x: size.width * 0.3 - glowR, y: -glowR * 0.3, width: glowR * 2, height: glowR * 2)
                context.fill(Circle().path(in: glowRect), with: .color(Color(red: 0.15, green: 0.2, blue: 0.35).opacity(0.04)))

                // Rain drops — varied layers
                for i in 0..<50 {
                    let fi = CGFloat(i)
                    let seed = sin(fi * 3.7 + 0.5) * 0.5 + 0.5
                    let layer = fi.truncatingRemainder(dividingBy: 3)
                    let x = seed * size.width + sin(fi * 0.7) * 8
                    let speed = 50 + layer * 30 + seed * 60
                    let y = (CGFloat(time * speed) + fi * 43).truncatingRemainder(dividingBy: size.height + 30) - 15
                    let length = 8 + layer * 4 + seed * 6
                    let alpha = 0.04 + (2 - layer) * 0.03 + seed * 0.04

                    var path = Path()
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x - 0.5, y: y + length))
                    context.stroke(path, with: .color(Color(red: 0.5, green: 0.7, blue: 0.9).opacity(alpha)), lineWidth: 0.4)
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct LiveFirefliesView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate

                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.02, green: 0.03, blue: 0.02)))

                // Soft ground glow
                let groundR = size.width * 0.5
                let groundRect = CGRect(x: size.width * 0.5 - groundR, y: size.height - groundR * 0.6, width: groundR * 2, height: groundR * 2)
                context.fill(Circle().path(in: groundRect), with: .color(Color(red: 0.06, green: 0.1, blue: 0.04).opacity(0.15)))

                for i in 0..<20 {
                    let fi = CGFloat(i)
                    let seed1 = sin(fi * 2.1 + 0.7) * 0.5 + 0.5
                    let seed2 = cos(fi * 1.9 + 1.3) * 0.5 + 0.5
                    let x = seed1 * size.width + sin(time * 0.25 + fi * 0.6) * 40
                    let y = seed2 * size.height + cos(time * 0.2 + fi * 0.9) * 30
                    let glow = (sin(time * 0.8 + fi * 1.7) * 0.5 + 0.5)

                    // Outer glow
                    let outerR = 6 + glow * 8
                    let outerRect = CGRect(x: x - outerR, y: y - outerR, width: outerR * 2, height: outerR * 2)
                    context.fill(Circle().path(in: outerRect), with: .color(Color(red: 0.95, green: 0.85, blue: 0.3).opacity(glow * 0.04)))

                    // Core
                    let coreR = 1.0 + glow * 1.5
                    let coreRect = CGRect(x: x - coreR, y: y - coreR, width: coreR * 2, height: coreR * 2)
                    context.fill(Circle().path(in: coreRect), with: .color(Color(red: 1.0, green: 0.95, blue: 0.5).opacity(0.1 + glow * 0.3)))
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct LiveNebulaView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let w = size.width
                let h = size.height

                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.01, green: 0.01, blue: 0.03)))

                // Large fluid color blobs — simulating mesh gradient
                let blobs: [(fx: CGFloat, fy: CGFloat, hue: CGFloat, sOff: CGFloat)] = [
                    (0.25, 0.3, 0.75, 0.0),
                    (0.7, 0.25, 0.55, 1.2),
                    (0.5, 0.65, 0.85, 2.5),
                    (0.3, 0.7, 0.6, 3.8),
                    (0.8, 0.6, 0.45, 5.0),
                ]

                for blob in blobs {
                    let cx = w * blob.fx + sin(time * 0.06 + blob.sOff) * w * 0.08
                    let cy = h * blob.fy + cos(time * 0.05 + blob.sOff * 0.7) * h * 0.06
                    let radius = min(w, h) * 0.35

                    let hue = (blob.hue + time * 0.005).truncatingRemainder(dividingBy: 1.0)

                    // Two layers for depth
                    let outerRect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
                    context.fill(Circle().path(in: outerRect), with: .color(Color(hue: hue, saturation: 0.5, brightness: 0.35).opacity(0.05)))

                    let innerR = radius * 0.5
                    let innerRect = CGRect(x: cx - innerR, y: cy - innerR, width: innerR * 2, height: innerR * 2)
                    context.fill(Circle().path(in: innerRect), with: .color(Color(hue: hue, saturation: 0.6, brightness: 0.5).opacity(0.04)))
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct LiveMatrixView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate

                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.01, green: 0.02, blue: 0.01)))

                let columns = 24
                let colWidth = size.width / CGFloat(columns)
                for col in 0..<columns {
                    let seed = sin(CGFloat(col) * 3.14 + 0.5) * 0.5 + 0.5
                    let speed = 25 + seed * 50
                    let length = 5 + Int(seed * 8)
                    for row in 0..<length {
                        let x = CGFloat(col) * colWidth + colWidth / 2
                        let baseY = (CGFloat(time * speed) + CGFloat(col) * 23).truncatingRemainder(dividingBy: size.height + 120) - 60
                        let y = baseY - CGFloat(row) * 14
                        let progress = CGFloat(row) / CGFloat(length)
                        let alpha = (1.0 - progress) * 0.25
                        let r: CGFloat = 1.5
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        let green = Color(red: 0.15 * (1.0 - progress), green: 0.8 * (1.0 - progress * 0.5), blue: 0.3 * (1.0 - progress))
                        context.fill(Circle().path(in: rect), with: .color(green.opacity(alpha)))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct LiveRippleView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate

                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.03, green: 0.04, blue: 0.08)))

                let centers: [(CGFloat, CGFloat, CGFloat)] = [
                    (0.3, 0.35, 0.0), (0.75, 0.55, 2.0), (0.45, 0.75, 4.0), (0.6, 0.2, 5.5),
                ]
                for (fx, fy, offset) in centers {
                    let cx = size.width * fx + sin(time * 0.04 + offset) * 15
                    let cy = size.height * fy + cos(time * 0.03 + offset) * 10
                    for ring in 0..<5 {
                        let phase = (time * 0.4 + offset + CGFloat(ring) * 0.8).truncatingRemainder(dividingBy: 4.0)
                        let maxRadius = max(size.width, size.height) * 0.3
                        let radius = phase / 4.0 * maxRadius
                        let alpha = (1.0 - phase / 4.0) * 0.06
                        let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
                        context.stroke(
                            Circle().path(in: rect),
                            with: .color(Color(red: 0.35, green: 0.65, blue: 0.9).opacity(alpha)),
                            lineWidth: 0.8
                        )
                    }
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
        case .honeycomb: "hexagon"
        case .crosshatch: "line.3.crossed.swirl.circle"
        case .bubo: "owl"
        case .none: "square.grid.3x3"
        }
    }

    private var livePreviewGradient: AnyShapeStyle {
        switch wallpaper.liveStyle {
        case .aurora:
            AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.15, green: 0.55, blue: 0.45), Color(red: 0.08, green: 0.12, blue: 0.35), Color(red: 0.01, green: 0.02, blue: 0.06)],
                startPoint: .top, endPoint: .bottom
            ))
        case .particles:
            AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.08, green: 0.08, blue: 0.12), Color(red: 0.04, green: 0.04, blue: 0.06)],
                startPoint: .top, endPoint: .bottom
            ))
        case .pulse:
            AnyShapeStyle(RadialGradient(
                colors: [Color(red: 0.12, green: 0.18, blue: 0.4), Color(red: 0.03, green: 0.03, blue: 0.08)],
                center: .center, startRadius: 0, endRadius: 30
            ))
        case .rain:
            AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.08, green: 0.1, blue: 0.18), Color(red: 0.03, green: 0.04, blue: 0.08)],
                startPoint: .top, endPoint: .bottom
            ))
        case .fireflies:
            AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.05, green: 0.08, blue: 0.04), Color(red: 0.02, green: 0.03, blue: 0.02)],
                startPoint: .bottom, endPoint: .top
            ))
        case .nebula:
            AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.18, green: 0.1, blue: 0.3), Color(red: 0.06, green: 0.04, blue: 0.15), Color(red: 0.01, green: 0.01, blue: 0.03)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        case .matrix:
            AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.03, green: 0.14, blue: 0.05), Color(red: 0.01, green: 0.02, blue: 0.01)],
                startPoint: .top, endPoint: .bottom
            ))
        case .ripple:
            AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.08, green: 0.15, blue: 0.25), Color(red: 0.03, green: 0.04, blue: 0.08)],
                startPoint: .top, endPoint: .bottom
            ))
        case .none:
            AnyShapeStyle(Color(white: 0.08))
        }
    }
}
