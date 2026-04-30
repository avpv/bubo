import SwiftUI

/// Thin marker line that names the Backlog overflow and carries inline
/// action-links to resolve it. Sits between the «fits today» tasks and
/// the «doesn't fit» tail in both `BacklogView` and `BacklogFullscreenView`.
///
/// Why a marker, not a section header: Birman — *don't label the obvious*.
/// «FITS TODAY» over the top tasks would say what's already implied by the
/// fact that they're in the backlog at all. Only the surprise (overflow)
/// gets a printed line, and that line *is* the affordance — the action-links
/// inside it resolve the overflow without an extra button.
///
/// Visual contract:
/// - The marker reads in the existing footnote-secondary tint (no destructive
///   red — the ring already shouts; the marker just labels). One signal per
///   state — Birman's «не дублируй сигналы».
/// - Action-links are tappable text in the accent color with an expanded
///   hit-area (Fitts: 28pt minimum even at footnote font size).
/// - On tap, the link's text is replaced by a `ProgressView()` until the
///   parent's async action returns. Birman: «постоянная мягкая обратная связь».
struct SpillOverMarker: View {
    /// Total minutes spilling over (sum of `overflowingTasks.durationMinutes`).
    let overflowMinutes: Int

    /// Count of tasks spilling over. Drives the marker's plural-aware
    /// phrasing — «1 task spills over» when there's literally one,
    /// «X h spill over» when the volume dominates.
    let overflowCount: Int

    /// Schedule the overflow set onto the calendar via the optimizer. Async
    /// because the optimizer call goes through `runQuickAction` which can
    /// take a beat; the marker shows a spinner during the run.
    let onSchedule: () async -> Void

    /// Optional secondary action-link, rendered only when the overflow set
    /// contains at least one urgent task. Mirrors the deleted «Deadlines»
    /// chip — surfaces the `deadlineMode` intent in its natural scope.
    let onFocusOnDeadlines: (() async -> Void)?

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isScheduling = false
    @State private var isFocusing = false

    var body: some View {
        HStack(spacing: DS.Spacing.xxs) {
            Text(volumeText)
                .foregroundStyle(skin.resolvedTextSecondary)

            Text(verbatim: "\u{00A0}·\u{00A0}")
                .foregroundStyle(skin.resolvedTextTertiary)

            actionLink(
                label: "schedule",
                isRunning: isScheduling,
                action: {
                    isScheduling = true
                    await onSchedule()
                    isScheduling = false
                }
            )
            // Disable both links while either is running — prevents double-fire
            // and matches Birman's «один сигнал состояния».
            .disabled(isScheduling || isFocusing)

            if let onFocus = onFocusOnDeadlines {
                Text(verbatim: "\u{00A0}·\u{00A0}or\u{00A0}")
                    .foregroundStyle(skin.resolvedTextTertiary)

                actionLink(
                    label: "focus on deadlines first",
                    isRunning: isFocusing,
                    action: {
                        isFocusing = true
                        await onFocus()
                        isFocusing = false
                    }
                )
                .disabled(isScheduling || isFocusing)
            }

            Spacer(minLength: 0)
        }
        .font(.footnote.weight(.medium).monospacedDigit())
        .padding(.vertical, DS.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Subviews

    /// Inline action-link styled as accent-coloured text. The hit-area is
    /// expanded with `.contentShape(Rectangle().inset(-DS.Spacing.xs))` so
    /// the tappable region is at least 28pt vertically even at footnote
    /// font size — Fitts.
    @ViewBuilder
    private func actionLink(
        label: String,
        isRunning: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Haptics.tap()
            Task { await action() }
        } label: {
            Group {
                if isRunning {
                    HStack(spacing: DS.Spacing.xxs) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(verbatim: runningLabel(for: label))
                            .foregroundStyle(skin.resolvedTextTertiary)
                    }
                } else {
                    Text(verbatim: label)
                        .foregroundStyle(skin.accentColor)
                        .underline(false)
                }
            }
            // Hit-area expanded vertically so the link is reachable even at
            // footnote font size. The visual stays text-sized; only the
            // tap region grows.
            .contentShape(Rectangle().inset(by: -DS.Spacing.xs))
        }
        .buttonStyle(.plain)
        .help(helpText(for: label))
    }

    // MARK: - Copy

    /// Plural-aware volume description. Birman: «говори о конкретном объекте,
    /// не об абстракции». Single-task overflow says so explicitly; otherwise
    /// the volume in time tends to be more useful (a glance answers «how
    /// much did I overcommit by»).
    private var volumeText: String {
        if overflowCount == 1 {
            return "1\u{00A0}task spills\u{00A0}over"
        }
        return "\(DS.formatMinutes(overflowMinutes)) spill\u{00A0}over"
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if overflowCount == 1 {
            parts.append("1\u{00A0}task spills over today")
        } else {
            parts.append("\(DS.formatMinutes(overflowMinutes)) spill over today")
        }
        parts.append("Tap «schedule» to fit them in")
        if onFocusOnDeadlines != nil {
            parts.append("or «focus on deadlines first» to prioritize urgent tasks")
        }
        return parts.joined(separator: ". ")
    }

    private func runningLabel(for label: String) -> String {
        switch label {
        case "schedule":                   return "scheduling…"
        case "focus on deadlines first":   return "focusing…"
        default:                           return "\(label)…"
        }
    }

    private func helpText(for label: String) -> String {
        switch label {
        case "schedule":
            return "Schedule the overflow tasks into free slots"
        case "focus on deadlines first":
            return "Run the optimizer with deadline priority"
        default:
            return label
        }
    }
}
