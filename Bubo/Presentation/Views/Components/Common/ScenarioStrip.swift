import SwiftUI

// MARK: - ScenarioStrip
//
// Horizontal stacked-bar miniature — segments of proportional width,
// each coloured by its calendar-colour tag (or a neutral fill for
// «gap / free»). Used to show «what a scenario looks like» at a
// glance:
//
// - Scenario picker card miniature — each elite from the MAP-Elites
//   archive shows up as a strip the user can read in <300 ms.
// - Slot picker free-time chart — same primitive, different segments
//   (booked / free / chosen-slot).
// - Future use: a mini-day-density bar in the menubar density spec.
//
// Single primitive, two semantic flavours via the `Segment.kind`
// enum: `.event(Color)` for opaque, calendar-coloured spans;
// `.gap` for the neutral connecting tissue between events.
//
// PRINCIPLES §7: colour carries meaning (which calendar). Gap
// segments fall back to a neutral `fg-1 14%` so semantic colours
// stay reserved for actual events.

/// A single segment in a `ScenarioStrip`. `flex` is the unitless
/// relative width; the strip lays segments out as flex-weights, so
/// the same `Segment` array reads correctly across narrow card
/// minis and wider day overviews.
struct ScenarioStripSegment: Identifiable {
    enum Kind {
        case event(Color)
        case gap
        /// Highlighted segment — a chosen slot in the slot picker,
        /// the «recommended» pick in scenario list, etc. Uses skin
        /// accent at full saturation.
        case highlight
    }

    let id: UUID
    let flex: Double
    let kind: Kind

    init(flex: Double, kind: Kind) {
        self.id = UUID()
        self.flex = max(0.001, flex)
        self.kind = kind
    }
}

/// Stacked-bar miniature of a schedule. Renders `segments` as
/// flex-weighted spans inside a single rounded container.
struct ScenarioStrip: View {
    let segments: [ScenarioStripSegment]
    let height: CGFloat
    let cornerRadius: CGFloat

    @Environment(\.activeSkin) private var skin

    init(
        segments: [ScenarioStripSegment],
        height: CGFloat = 14,
        cornerRadius: CGFloat = 4
    ) {
        self.segments = segments
        self.height = height
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                Rectangle()
                    .fill(fill(for: segment.kind))
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .layoutPriority(segment.flex)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Schedule preview, \(segments.count) segments")
    }

    private func fill(for kind: ScenarioStripSegment.Kind) -> Color {
        switch kind {
        case .event(let colour): return colour
        case .gap:               return skin.resolvedTextPrimary.opacity(0.14)
        case .highlight:         return skin.accentColor
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("ScenarioStrip · variants") {
    VStack(alignment: .leading, spacing: DS.Spacing.lg) {
        // Scenario card — Deep-morning (recommended)
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Deep-morning · 0.91").font(.callout.weight(.semibold))
            ScenarioStrip(segments: [
                .init(flex: 3.0, kind: .event(.blue)),
                .init(flex: 1.5, kind: .event(.orange)),
                .init(flex: 0.5, kind: .gap),
                .init(flex: 1.0, kind: .event(.purple)),
                .init(flex: 0.7, kind: .gap),
                .init(flex: 1.0, kind: .event(.green)),
            ])
        }

        // Scenario card — Sprint-finish
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Sprint-finish · 0.83").font(.callout.weight(.semibold))
            ScenarioStrip(segments: [
                .init(flex: 1.0, kind: .event(.blue)),
                .init(flex: 0.5, kind: .event(.orange)),
                .init(flex: 1.0, kind: .gap),
                .init(flex: 4.0, kind: .event(.blue)),
                .init(flex: 1.0, kind: .event(.green)),
            ])
        }

        // Slot picker — free-time chart with chosen slot highlighted
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Today · 5 h 18 min free").font(.callout.weight(.medium))
            ScenarioStrip(segments: [
                .init(flex: 2.0, kind: .gap),
                .init(flex: 1.0, kind: .highlight),
                .init(flex: 1.5, kind: .gap),
                .init(flex: 1.0, kind: .event(.purple)),
                .init(flex: 2.5, kind: .gap),
            ], height: 6, cornerRadius: 3)
        }
    }
    .padding()
    .frame(width: 360)
}
#endif
