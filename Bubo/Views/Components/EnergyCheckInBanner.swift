import SwiftUI

// MARK: - Energy Check-In Banner
//
// Birman: one action, one result. Tap a level — done.
// The 1–5 scale is self-explanatory with endpoint labels ("low"/"high")
// and a semantic color gradient (warning → neutral → success).
// Sits alongside SmartBanner, not blocking it.

struct EnergyCheckInBanner: View {
    @Environment(\.activeSkin) private var skin

    let onRecord: (Int) -> Void
    let onDismiss: () -> Void

    private static let levels = 1...5

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

            // Endpoint label — semantic anchor for the scale
            Text("low")
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextTertiary)

            ForEach(Self.levels, id: \.self) { level in
                Button {
                    Haptics.tap()
                    onRecord(level)
                } label: {
                    Text("\(level)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(colorForLevel(level))
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(colorForLevel(level).opacity(DS.Opacity.lightFill))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Energy level \(level) of 5")
            }

            Text("high")
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextTertiary)

            Button {
                Haptics.tap()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Semantic color gradient: 1–2 = warning (orange), 3 = neutral, 4–5 = success (green).
    /// Birman §7: red/green/orange always system colors.
    private func colorForLevel(_ level: Int) -> Color {
        switch level {
        case 1, 2: return DS.Colors.warning
        case 4, 5: return DS.Colors.success
        default:   return skin.resolvedTextPrimary
        }
    }
}
