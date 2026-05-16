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
                .foregroundStyle(skin.resolvedTextPrimary)
        }
        // PRINCIPLES §2 — density: the banner carries one icon and one
        // footnote-sized line of text, so 16/12 inner padding made the
        // capsule sit visually heavier than the message it carries.
        // 12/8 keeps it readable without dominating the popover when
        // a network blip surfaces it.
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .adaptiveBadgeFill(color)
        .clipShape(Capsule())
        // Status banner sits inside the popover body, on the card plane (z1).
        .elevation(.z1, skin: skin)
        // Level 1: unified outer content margin so the banner hangs on
        // the same vertical axis as the rest of the popover chrome.
        // Leading-anchored: an `infinity` frame ensures the row claims
        // the full popover width so the pill sits against the left
        // margin alongside the header title; without this, the
        // intrinsic-width capsule drifted to whichever alignment the
        // host container happened to use (often centre).
        .padding(.horizontal, DS.Spacing.contentMargin)
        .padding(.vertical, DS.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
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
