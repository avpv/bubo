import SwiftUI

// MARK: - Smart Banner
//
// A thin, single-line notice rendered above the event list when the
// SuggestionEngine surfaces a contextually relevant optimization request.
// Tapping the banner opens the CommandPalette seeded with that request.
// Dismissing it silences the banner for the rest of the session.

struct SmartBanner: View {
    @Environment(\.activeSkin) private var skin

    let request: OptimizationRequest
    let reason: String
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "lightbulb.max.fill")
                .font(.caption)
                .foregroundStyle(skin.accentColor)
                .accessibilityHidden(true)

            Text(reason)
                .font(.caption)
                .foregroundStyle(skin.resolvedTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: DS.Spacing.xs)

            Button {
                Haptics.tap()
                onTap()
            } label: {
                HStack(spacing: 2) {
                    Text(request.name ?? "Optimize")
                        .font(.caption.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(skin.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Run \(request.name ?? "optimization")")

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
            .accessibilityLabel("Dismiss suggestion")
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
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.xs)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
