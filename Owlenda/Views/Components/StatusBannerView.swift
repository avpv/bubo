import SwiftUI

struct StatusBanner: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.caption)
                .symbolRenderingMode(.hierarchical)
            Text(text)
                .font(.caption)
        }
        .foregroundColor(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
        .background(DS.Colors.badgeFill(color))
        .accessibilityElement(children: .combine)
        .transition(
            .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .top))
            )
        )
    }
}
