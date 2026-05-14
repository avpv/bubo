import SwiftUI

// MARK: - Linear Progress Bar
//
// Shared track + fill bar used in:
//
//   • Subtask checklist progress (`.tp-progress`) — accent fill,
//     4 pt track, fg-1 8 % background.
//   • Slot-picker capacity bar (`.sp-progress`) — same 4 pt bar with a
//     warning tint when conflict tasks have been added.
//   • Tomorrow-banner ETA proxy, occasional inline metric bars.
//
// Single primitive ensures every bar in the popover sits on the same
// height (4 pt), uses the same radius (radiusSm / 2) and the same
// quiet track tint (fg-1 8 %). Bars in different roles only differ in
// `tone` (the fill colour family) and `value` (0…1, clamped). Birman:
// «one shape for one role».

struct ProgressBar: View {
    /// 0…1. Clamped — out-of-range inputs render as 0 / full instead
    /// of overflowing the track.
    let value: Double
    var tone: BannerTone = .accent
    var height: CGFloat = 4

    @Environment(\.activeSkin) private var skin

    var body: some View {
        let tint = tone.color(skin: skin)
        let clamped = min(max(value, 0), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(skin.resolvedTextPrimary.opacity(DS.Mix.surfaceDivider))
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(tint)
                    .frame(width: max(0, proxy.size.width * CGFloat(clamped)))
            }
        }
        .frame(height: height)
        .accessibilityValue("\(Int(clamped * 100)) percent")
    }
}
