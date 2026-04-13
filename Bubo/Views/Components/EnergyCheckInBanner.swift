import SwiftUI

// MARK: - Energy Check-In Banner
//
// Birman: one action, one result. Tap a level — done.
// §2 Density: numbers + semantic colour communicate the scale;
//     no endpoint labels needed. Hit targets ≥ 28 pt (HIG floor).
// §6 Motion: transition degrades gracefully with Reduce Motion.
// §7 Colour: orange (warning) → neutral → green (success) from system.
// §8 Typography: SF Symbols always .hierarchical.

struct EnergyCheckInBanner: View {
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onRecord: (Int) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "bolt.fill")
                .font(.caption)
                .foregroundStyle(skin.accentColor)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text("Energy?")
                .font(.caption)
                .foregroundStyle(skin.resolvedTextPrimary)
                .lineLimit(1)

            Spacer(minLength: DS.Spacing.xs)

            // 1–5 scale: visual circle 20 pt, tappable frame 28 pt (HIG §2).
            ForEach(1...5, id: \.self) { level in
                Button {
                    Haptics.tap()
                    onRecord(level)
                } label: {
                    Text("\(level)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(colorForLevel(level))
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(colorForLevel(level).opacity(DS.Opacity.lightFill))
                        )
                }
                .buttonStyle(.plain)
                .frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)
                .contentShape(Rectangle())
                .accessibilityLabel("Energy level \(level) of 5")
            }

            Button {
                Haptics.tap()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)
            .accessibilityLabel("Dismiss energy check-in")
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .fill(skin.accentColor.opacity(DS.Opacity.lightFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(skin.accentColor.opacity(DS.Opacity.subtleBorder), lineWidth: DS.Border.thin)
        )
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.top, DS.Spacing.xs)
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }

    /// Semantic colour: 1–2 warning, 3 accent (neutral), 4–5 success.
    /// §7: system colours for semantic meaning; accent for neutral state.
    private func colorForLevel(_ level: Int) -> Color {
        switch level {
        case 1, 2: return DS.Colors.warning
        case 4, 5: return DS.Colors.success
        default:   return skin.accentColor
        }
    }
}
