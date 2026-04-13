import SwiftUI

// MARK: - Energy Check-In Banner
//
// One-tap energy rating (1–5) that feeds the personal energy curve.
// Replaces the SmartBanner slot when a check-in is due.
// Birman: one action, one result. Tap a level — done.

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

            // 1–5 scale. All buttons share one style — they're equivalent
            // options in a picker, not status indicators (§7: semantic colours
            // are not ornaments — orange/green must mean warning/success,
            // not "low"/"high").
            ForEach(1...5, id: \.self) { level in
                Button {
                    Haptics.tap()
                    onRecord(level)
                } label: {
                    Text("\(level)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(skin.accentColor)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(skin.accentColor.opacity(DS.Opacity.lightFill))
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
}
