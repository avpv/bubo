import SwiftUI
import BuboDomain

/// Slim 10-point sparkline of the user's predicted energy curve across
/// the working day, plus a now-marker and a one-word verdict
/// («Trough · light tasks», «Peak · deep work»). Sits just under the
/// header and above the Now-zone — the first thing the eye lands on
/// after the date strip.
///
/// Curve values are 0…1 with one point per hour. The view picks the
/// segment that lies inside `workingHours` so the bars fill the ribbon
/// from edge to edge regardless of how long the workday is.
struct EnergyRibbonView: View {

    /// Full 24-hour curve from `EnergyCheckInService.predictedCurve(...)`.
    let curve: [Double]
    /// User's working hours bracket (e.g. 9...18). Determines which
    /// segment of the 24h curve is rendered.
    let workingHours: ClosedRange<Int>
    /// Current wall-clock time — drives the vertical now-marker line.
    let now: Date

    @Environment(\.activeSkin) private var skin

    private let ribbonHeight: CGFloat = 12

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            sparkline
                .frame(height: ribbonHeight)
                .frame(maxWidth: .infinity)

            Text(verdict)
                .font(DS.Typography.machineHint)
                .foregroundStyle(skin.resolvedTextTertiary)
                .fixedSize()
        }
        .padding(.horizontal, DS.Spacing.contentMargin)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Energy curve: \(verdict)")
    }

    private var workingValues: [Double] {
        let lower = max(0, workingHours.lowerBound)
        let upper = min(23, workingHours.upperBound)
        guard upper >= lower, curve.count >= 24 else { return [] }
        return Array(curve[lower...upper])
    }

    @ViewBuilder
    private var sparkline: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Baseline
                Rectangle()
                    .fill(skin.resolvedTextPrimary.opacity(0.06))
                    .frame(height: 1)
                    .offset(y: ribbonHeight - 1)

                // Bars
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(Array(workingValues.enumerated()), id: \.offset) { _, v in
                        Capsule(style: .continuous)
                            .fill(barColor(for: v))
                            .frame(height: max(1, ribbonHeight * CGFloat(max(0.1, v))))
                    }
                }
                .frame(width: geo.size.width, height: ribbonHeight, alignment: .bottom)

                // Now marker
                if let x = nowX(in: geo.size.width) {
                    Rectangle()
                        .fill(skin.resolvedDestructiveColor.opacity(0.7))
                        .frame(width: 1, height: ribbonHeight + 3)
                        .offset(x: x, y: -1)
                }
            }
        }
    }

    private func barColor(for v: Double) -> Color {
        // Map 0→tertiary, 1→accent. Two-stop interpolation by opacity.
        let baseAlpha = 0.25 + 0.55 * v
        return skin.accentColor.opacity(baseAlpha)
    }

    private func nowX(in width: CGFloat) -> CGFloat? {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let lower = workingHours.lowerBound
        let upper = workingHours.upperBound
        guard hour >= lower, hour <= upper else { return nil }
        let count = max(1, upper - lower + 1)
        let cellWidth = width / CGFloat(count)
        let progressInHour = CGFloat(minute) / 60.0
        return cellWidth * (CGFloat(hour - lower) + progressInHour)
    }

    private var verdict: String {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        guard workingHours.contains(hour), curve.count >= 24 else {
            return "After hours"
        }
        let v = curve[hour]
        if v >= 0.75 { return "Peak \u{00B7} deep work" }
        if v >= 0.5  { return "Steady \u{00B7} focused work" }
        if v >= 0.3  { return "Soft \u{00B7} reviews & calls" }
        return "Trough \u{00B7} light tasks"
    }
}

#if DEBUG
#Preview {
    let sample: [Double] = (0..<24).map { h in
        let peak = 10.0
        let sigma = 3.0
        let x = Double(h) - peak
        return exp(-(x * x) / (2 * sigma * sigma))
    }
    return VStack {
        EnergyRibbonView(curve: sample, workingHours: 9...18, now: Date())
        EnergyRibbonView(curve: sample, workingHours: 8...20, now: Date())
    }
    .frame(width: 360)
    .background(Color(white: 0.98))
}
#endif
