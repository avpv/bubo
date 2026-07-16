import SwiftUI

struct StatusBanner: View {
    @Environment(\.activeSkin) private var skin
    let icon: String
    let text: String
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.footnote)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
            Text(text)
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
        }
        // PRINCIPLES §5 — status is not an action: this banner is
        // non-interactive, so it must not dress like a button. The tinted
        // capsule fill it used to share with `PermissionBannerRow` (a real
        // Button) made the two indistinguishable; the informational banner
        // now reads as a quiet icon + footnote row, and the pill shape
        // stays reserved for surfaces that respond to a click (HIG color:
        // don't stylize noninteractive text like interactive controls).
        .padding(.vertical, DS.Spacing.sm)
        // Level 1: unified outer content margin so the banner hangs on
        // the same vertical axis as the rest of the popover chrome.
        .padding(.horizontal, DS.Spacing.contentMargin)
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
