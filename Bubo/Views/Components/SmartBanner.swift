import SwiftUI

// MARK: - Smart Banner
//
// One-line contextual suggestion with a Run button.
// Tapping Run executes immediately (no palette). Undo via toast.
// Birman: one action, one result, one undo.

struct SmartBanner: View {
    @Environment(\.activeSkin) private var skin

    let request: OptimizationRequest
    let reason: String
    /// Run the request directly — no palette, no configuration.
    let onRun: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "lightbulb.max.fill")
                .font(.footnote)
                .foregroundStyle(skin.accentColor)
                .accessibilityHidden(true)

            Text(reason)
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: DS.Spacing.xs)

            // Run button — executes immediately
            Button {
                Haptics.tap()
                onRun()
            } label: {
                Text("Run")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.pillVertical)
                    .background(Capsule().fill(skin.accentColor))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Run: \(reason)")

            Button {
                Haptics.tap()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
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
        // Level 4 (final): the banner now lives inside the timeline platter
        // card, so it loses its own outer horizontal margin and hangs on the
        // same vertical axis as everything else on the card. A small leading
        // indent (`sm`) keeps it from touching the card's rounded corners.
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.top, DS.Spacing.xs)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
