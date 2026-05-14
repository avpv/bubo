import SwiftUI

struct StatusBanner: View {
    @Environment(\.activeSkin) private var skin
    let icon: String
    let text: String
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption.weight(.medium))
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(skin.resolvedTextSecondary)
                .lineLimit(1)
        }
        // PRINCIPLES §2 — density: the banner carries one icon and one
        // small line of text. The previous 12/8 capsule + drop shadow
        // read as a primary alert; this is a passive status indicator
        // («cached data», «offline») so 10/4 inside a hairline-only chip
        // keeps it readable without competing with the day's events.
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xxs)
        .background(
            Capsule().fill(color.opacity(DS.Opacity.subtleFill))
        )
        .overlay(
            Capsule().strokeBorder(color.opacity(DS.Opacity.softAccent), lineWidth: DS.Border.thin)
        )
        // Level 1: unified outer content margin so the banner hangs on
        // the same vertical axis as the rest of the popover chrome.
        .padding(.horizontal, DS.Spacing.contentMargin)
        .padding(.vertical, DS.Spacing.xxs)
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
