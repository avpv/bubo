import SwiftUI

struct StatusBanner: View {
    let icon: String
    let text: String
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.caption)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
            Text(text)
                .font(.caption)
        }
        .foregroundColor(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
        .adaptiveBadgeFill(color)
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
