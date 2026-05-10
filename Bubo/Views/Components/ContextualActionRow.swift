import SwiftUI

/// Single contextual action row used by `SmartActions`. One leading symbol,
/// primary verb (accent), optional secondary subtext, and a trailing slot
/// that swaps between a `Run` label, a spinner, or a `⌘K` hint depending
/// on `kind`.
///
/// Birman: «information is a button». The whole row is the tap target
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

    /// Single-line layout — verb and subtext share one row separated by
    /// a middle dot, subtext keeps its tertiary `machineHint` voice. Used
    /// by the inline backlog where a 2-line action row eats too much of
    /// the limited list height. Default `false` preserves the canonical
    /// stacked layout for fullscreen and standalone hosts.
    var compact: Bool = false

    /// Override for the `.run` trailing label. Defaults to «Run»; the
    /// backlog's ready-to-plan banner passes «Plan» here to match
    /// `ui_kits/backlog/index.html` `.tip-row .plan-link`. Ignored when
    /// `kind == .discover` (the ⌘K hint owns the slot).
    var runLabel: String = "Run"

    @Environment(\.activeSkin) private var skin
    @State private var isRunning = false
    /// Hover state — used to paint a quiet accent-tinted row background
    /// so the user reads the *whole* row as one tap target (Fitts: the
    /// hit area is the row, not just the trailing label). Without this,
    /// the only affordance was the leading icon/text colour matching
    /// `skin.accentColor`, which is easy to miss against a calm palette.
    @State private var isHovered = false

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

                if compact {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(verb)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(skin.accentColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)

                        if let subtext, !subtext.isEmpty {
                            Text("· \(subtext)")
                                .font(DS.Typography.machineHint)
                                .foregroundStyle(skin.resolvedTextTertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .contentTransition(.numericText())
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verb)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(skin.accentColor)
                            // Up to 2 lines in stacked layout so soft-state
                            // reasons like "task5 due soon · 7 meetings —
                            // batch them?" don't truncate to "batch the…"
                            // and leave the user guessing what Run does.
                            // Compact path stays at one line for the
                            // height-budgeted main bar.
                            .lineLimit(2)
                            .truncationMode(.tail)

                        if let subtext, !subtext.isEmpty {
                            // `DS.Typography.machineHint` — monospaced footnote
                            // in tertiary; this is the «machine speech» voice
                            // (subtext under SmartActions, ghost-slot hints,
                            // duration guesses, ⌘K). Single shared voice so the
                            // user learns to recognise «this is the computer
                            // thinking out loud», never their own input.
                            // `numericText` transition keeps the digit columns
                            // («4 tasks · 4 h 32 min over») smooth as the
                            // forecast updates — without it, every overflow
                            // delta swaps with a hard cut.
                            Text(subtext)
                                .font(DS.Typography.machineHint)
                                .foregroundStyle(skin.resolvedTextTertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .contentTransition(.numericText())
                        }
                    }
                }

                Spacer(minLength: DS.Spacing.sm)

                trailing
                    .frame(minWidth: 32, alignment: .trailing)
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, compact ? DS.Spacing.xxs : DS.Spacing.xs)
            .background(
                // Quiet accent fill on hover. Same `subtleFill` opacity
                // the add-task field uses for its idle state — keeps
                // the hover read «active surface» without shouting.
                RoundedRectangle(cornerRadius: DS.Size.subtleCornerRadius, style: .continuous)
                    .fill(skin.accentColor.opacity(isHovered ? DS.Opacity.subtleFill : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        // Full text in a tooltip so even when the row truncates (compact
        // bar, long reasons), the user can hover to see the verb +
        // subtext in full. Empty subtext collapses to verb-only.
        .help(tooltipText)
        .onHover { hovering in
            // `withAnimation` hop on hover to soften the colour swap;
            // SwiftUI's default for state changes inside `onHover` is
            // a hard cut, which feels twitchy on macOS.
            withAnimation(DS.Animation.quick) { isHovered = hovering }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var trailing: some View {
        switch kind {
        case .run where isRunning:
            ProgressView()
                .controlSize(.mini)
        case .run:
            Text(runLabel)
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

    /// Full verb + subtext for the row's tooltip. Lets the user hover
    /// to read the complete description even when the visible label
    /// truncated (compact bar, long composer reasons).
    private var tooltipText: String {
        if let subtext, !subtext.isEmpty { return "\(verb) — \(subtext)" }
        return verb
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
