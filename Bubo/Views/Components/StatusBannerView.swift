import SwiftUI

struct StatusBanner: View {
    let icon: String
    let text: String
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
            Text(text)
                .font(.caption)
                .foregroundStyle(DS.Colors.textPrimary)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .adaptiveBadgeFill(color)
        .clipShape(Capsule())
        .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.ambientRadius, y: DS.Shadows.ambientY)
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(text)")
        .transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .top))
                )
        )
    }
}
