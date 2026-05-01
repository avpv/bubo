import SwiftUI

/// Single contextual action row used by `SmartActions`. One leading symbol,
/// primary verb (accent), optional secondary subtext, and a trailing slot
/// that swaps between a `Run` label, a spinner, or a `⌘K` hint depending
/// on `kind`.
///
/// Birman: «информация — это кнопка». The whole row is the tap target
/// (Fitts: ≥28pt vertical hit-area), so the user doesn't have to aim at
/// the trailing label. State transitions go through the same async pattern
/// `SpillOverMarker.actionLink` used to use — tap → spinner → result.
///
/// The row carries no chrome of its own (no filled capsule, no border).
/// Hierarchy comes from typography weight + accent colour, not boxes —
/// the host card chrome is the container.
struct ContextualActionRow: View {

    enum Kind {
        /// Primary action — taps run an async closure, trailing reads `Run`.
        case run
        /// Calm-state discovery — taps open a popover, trailing reads `⌘K`.
        case discover
    }

    let icon: String
    let verb: String
    let subtext: String?
    let kind: Kind
    let action: () async -> Void

    @Environment(\.activeSkin) private var skin
    @State private var isRunning = false

    var body: some View {
        Button {
            guard !isRunning else { return }
            Haptics.tap()
            switch kind {
            case .run:
                isRunning = true
                Task {
                    await action()
                    isRunning = false
                }
            case .discover:
                Task { await action() }
            }
        } label: {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(skin.accentColor)
                    .frame(width: DS.Size.iconSmall, alignment: .center)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verb)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(skin.accentColor)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let subtext, !subtext.isEmpty {
                        // `DS.Typography.machineHint` — monospaced footnote
                        // in tertiary; this is the «machine speech» voice
                        // (subtext under SmartActions, ghost-slot hints,
                        // duration guesses, ⌘K). Single shared voice so the
                        // user learns to recognise «this is the computer
                        // thinking out loud», never their own input.
                        Text(subtext)
                            .font(DS.Typography.machineHint)
                            .foregroundStyle(skin.resolvedTextTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: DS.Spacing.sm)

                trailing
                    .frame(minWidth: 32, alignment: .trailing)
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var trailing: some View {
        switch kind {
        case .run where isRunning:
            ProgressView()
                .controlSize(.mini)
        case .run:
            Text("Run")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(skin.accentColor)
        case .discover:
            // Same `machineHint` voice as the row's subtext — the ⌘K hint is
            // a quiet «by the way, the keyboard works too», not a primary
            // action label.
            Text("\u{2318}K")
                .font(DS.Typography.machineHint)
                .foregroundStyle(skin.resolvedTextTertiary)
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = [verb]
        if let subtext, !subtext.isEmpty { parts.append(subtext) }
        switch kind {
        case .run:      parts.append("Run")
        case .discover: parts.append("Command-K")
        }
        return parts.joined(separator: ". ")
    }
}
