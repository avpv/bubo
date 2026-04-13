import SwiftUI

// MARK: - Energy Check-In Banner

/// Compact inline banner that asks the user to report their current energy level (1–5).
/// Appears 2-3 times per workday in place of the SmartBanner when a check-in is due.
///
/// Design: follows the same visual language as SmartBanner — light accent background,
/// icon + label + action + dismiss, single-line height.
struct EnergyCheckInBanner: View {
    @Environment(\.activeSkin) private var skin

    let onRecord: (Int) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("\u{1F50B}")
                .font(.caption)
                .accessibilityHidden(true)

            Text("How's your energy?")
                .font(.caption)
                .foregroundStyle(skin.resolvedTextPrimary)
                .lineLimit(1)

            Spacer(minLength: DS.Spacing.xs)

            // 1–5 energy level buttons
            ForEach(1...5, id: \.self) { level in
                Button {
                    Haptics.tap()
                    onRecord(level)
                } label: {
                    Text("\(level)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(level <= 2 ? Color.orange : level >= 4 ? Color.green : skin.resolvedTextPrimary)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(skin.accentColor.opacity(level == 3 ? 0.08 : 0.15))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Energy level \(level)")
            }

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
                .fill(skin.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(skin.accentColor.opacity(0.15), lineWidth: DS.Border.thin)
        )
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.top, DS.Spacing.xs)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
