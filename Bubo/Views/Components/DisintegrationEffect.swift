import SwiftUI

// MARK: - Disintegration Particle

private struct Particle {
    let id: Int
    let initialX: CGFloat
    let initialY: CGFloat
    let color: Color
    let size: CGFloat
    let targetOffsetX: CGFloat
    let targetOffsetY: CGFloat
    let delay: Double
}

// MARK: - Disintegration Modifier

/// Applies a "Thanos snap" / Telegram-style dust disintegration when `isDisintegrating` becomes true.
/// The view breaks into particles that scatter upward-right and fade out in a wave.
struct DisintegrationModifier: ViewModifier {
    let isDisintegrating: Bool
    var onComplete: (() -> Void)?

    @State private var particles: [Particle] = []
    @State private var animationStart: Date?
    @State private var contentOpacity: CGFloat = 1
    @State private var hasTriggered = false
    @State private var viewSize: CGSize = .zero
    @State private var collapsedHeight: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.activeSkin) private var skin

    private let columns = 28
    private let rows = 8
    private let animationDuration: Double = 0.9

    func body(content: Content) -> some View {
        content
            .opacity(contentOpacity)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { viewSize = geo.size }
                        .onChange(of: geo.size) { _, newSize in
                            if collapsedHeight == nil { viewSize = newSize }
                        }
                }
            }
            .overlay {
                if !particles.isEmpty, let start = animationStart {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                        let elapsed = timeline.date.timeIntervalSince(start)
                        Canvas { ctx, _ in
                            for p in particles {
                                let pElapsed = max(0, elapsed - p.delay)
                                let pDuration = animationDuration * 0.65
                                let t = min(pElapsed / pDuration, 1.0)

                                // Ease-out cubic for natural deceleration
                                let eased = 1 - pow(1 - t, 3)

                                let ox = p.initialX + p.targetOffsetX * eased
                                let oy = p.initialY + p.targetOffsetY * eased

                                // Fade out after 30% progress
                                let fadeT = max(0, (t - 0.3) / 0.7)
                                let opacity = max(0, 1 - fadeT)

                                // Shrink as they fly
                                let currentSize = p.size * (1 - eased * 0.5)
                                let rect = CGRect(
                                    x: ox - currentSize / 2,
                                    y: oy - currentSize / 2,
                                    width: currentSize,
                                    height: currentSize
                                )
                                ctx.opacity = opacity
                                ctx.fill(Path(ellipseIn: rect), with: .color(p.color))
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: collapsedHeight)
            .clipped()
            .onChange(of: isDisintegrating) { _, newValue in
                if newValue && !hasTriggered {
                    triggerDisintegration()
                }
            }
    }

    private func triggerDisintegration() {
        guard !hasTriggered else { return }
        hasTriggered = true

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) {
                contentOpacity = 0
                collapsedHeight = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                onComplete?()
            }
            return
        }

        generateParticles()
        animationStart = Date()

        // Fade out original content quickly
        withAnimation(.easeIn(duration: animationDuration * 0.4).delay(0.05)) {
            contentOpacity = 0
        }

        // Collapse height after particles have mostly scattered
        let collapseDelay = animationDuration * 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay) {
            withAnimation(.easeInOut(duration: 0.35)) {
                collapsedHeight = 0
            }
        }

        // Remove from data source after full animation
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay + 0.4) {
            onComplete?()
        }
    }

    private func generateParticles() {
        let w = max(viewSize.width, 100)
        let h = max(viewSize.height, 40)

        let cellW = w / CGFloat(columns)
        let cellH = h / CGFloat(rows)

        let accent = skin.accentColor
        let dustColors: [Color] = [
            accent.opacity(0.7),
            accent.opacity(0.5),
            accent.opacity(0.9),
            skin.resolvedTextSecondary.opacity(0.6),
            skin.resolvedTextPrimary.opacity(0.35),
        ]

        var result: [Particle] = []

        for row in 0..<rows {
            for col in 0..<columns {
                let x = CGFloat(col) * cellW + cellW / 2
                let y = CGFloat(row) * cellH + cellH / 2

                // Wave from right to left (right side scatters first)
                let normalizedX = CGFloat(col) / CGFloat(columns)
                let delay = (1.0 - normalizedX) * 0.3 + Double.random(in: 0...0.08)

                // Scatter mostly upward-right
                let angle = Double.random(in: -Double.pi * 0.8 ... -Double.pi * 0.15)
                let distance = CGFloat.random(in: 35...110)
                let targetX = cos(angle) * distance + CGFloat.random(in: 15...55)
                let targetY = sin(angle) * distance - CGFloat.random(in: 8...35)

                result.append(Particle(
                    id: row * columns + col,
                    initialX: x,
                    initialY: y,
                    color: dustColors[Int.random(in: 0..<dustColors.count)],
                    size: CGFloat.random(in: 2...5),
                    targetOffsetX: targetX,
                    targetOffsetY: targetY,
                    delay: delay
                ))
            }
        }

        particles = result
    }
}

// MARK: - View Extension

extension View {
    /// Applies the Thanos-style dust disintegration effect.
    /// When `isDisintegrating` becomes true, the view breaks apart into particles that scatter and fade.
    func disintegrate(when isDisintegrating: Bool, onComplete: (() -> Void)? = nil) -> some View {
        modifier(DisintegrationModifier(isDisintegrating: isDisintegrating, onComplete: onComplete))
    }
}
