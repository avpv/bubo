import SwiftUI

// MARK: - Timeline NOW Divider
//
// Mirrors the prototype's `.now-line` — a thin red rule with the
// "NOW · 10:48" caption centred between two segments, drawn between
// past and current events inside the day-section.
//
// Spec (from `prototype-spec.md` §1 "Today Popover · Dimensions"):
//   • flex row, gap 8 px, padding 4 4
//   • font 600 10/1 uppercase, letter-spacing 0.06 em
//   • text colour `--system-red`
//   • two flex-1 rules ::before / ::after at red 50 % opacity, 1 px

struct TimelineNowRule: View {
    let now: Date

    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Rectangle()
                .fill(skin.resolvedDestructiveColor)
                .opacity(DS.Opacity.half)
                .frame(height: 1)
            Text("NOW · \(timeLabel)")
                .font(.system(size: 10, weight: .semibold, design: skin.resolvedFontDesign))
                .tracking(0.6)
                .foregroundStyle(skin.resolvedDestructiveColor)
            Rectangle()
                .fill(skin.resolvedDestructiveColor)
                .opacity(DS.Opacity.half)
                .frame(height: 1)
        }
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.vertical, DS.Spacing.xs)
        .accessibilityLabel("Current time \(timeLabel)")
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("H:mm")
        return formatter.string(from: now)
    }
}
