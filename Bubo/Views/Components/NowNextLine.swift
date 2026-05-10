import SwiftUI

/// Single-line «what's happening / what's next» status surface.
/// Closes the J-Triage gap: the user opens Bubo and gets the
/// answer to «what should I be doing right now and what's after»
/// without scanning the timeline.
///
/// Three rendering states:
/// - **Inside an event**: «▶ <title> · 32 m left  →  Next 15:00 <title>»
/// - **Between events, next is soon (< 60 min)**: «Next 15:00 <title> · in 6 min»
/// - **Nothing now, nothing soon**: the row hides entirely (host
///   should gate visibility on `hasContent`).
///
/// Birman: «information on the main screen», not behind a click and not
/// in the timeline — the user needs a direct answer to «what's now».
struct NowNextLine: View {
    @Environment(\.activeSkin) private var skin

    /// Events on the day the user is looking at, used to find the
    /// current and next event. Caller passes the same `dayGroup.events`
    /// that drive the timeline.
    let events: [CalendarEvent]
    /// Wall-clock «now» — host ticks once per minute and forwards it
    /// here so the line stays fresh without per-row timers.
    let now: Date
    /// Open-button counterpart for «N overdue» — taps open the
    /// fullscreen backlog so the user can act on them. nil = the
    /// overdue chip is hidden.
    var overdueCount: Int = 0
    var onOpenBacklog: (() -> Void)? = nil

    var body: some View {
        if hasContent {
            HStack(spacing: DS.Spacing.sm) {
                if let content = renderContent {
                    content
                }
                Spacer(minLength: DS.Spacing.xs)
                if overdueCount > 0, let opener = onOpenBacklog {
                    overdueChip(opener)
                }
            }
            .font(.footnote)
            .padding(.horizontal, DS.Spacing.contentMargin)
            .padding(.vertical, DS.Spacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Whether the host should render this line at all. Used by
    /// the parent layout so it doesn't reserve vertical space when
    /// there's nothing to show.
    var hasContent: Bool {
        renderContent != nil || overdueCount > 0
    }

    private var renderContent: AnyView? {
        if let current = currentEvent {
            let nextLabel = nextEvent.map { " → \(timeLabel($0.startDate)) \(truncate($0.title, 20))" } ?? ""
            let minutesLeft = max(0, Int(current.endDate.timeIntervalSince(now) / 60))
            return AnyView(
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(skin.accentColor)
                    Text(truncate(current.title, 28))
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .lineLimit(1)
                    Text("· \(minutesLeft)\u{00A0}min\u{00A0}left\(nextLabel)")
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            )
        }
        if let upcoming = nextEvent,
           upcoming.startDate.timeIntervalSince(now) < 60 * 60 {
            let minutes = max(0, Int(upcoming.startDate.timeIntervalSince(now) / 60))
            return AnyView(
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "arrow.right.circle")
                        .font(.caption)
                        .foregroundStyle(skin.accentColor)
                    Text("Next \(timeLabel(upcoming.startDate)) \(truncate(upcoming.title, 28))")
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .lineLimit(1)
                    Text("· in \(minutes)\u{00A0}min")
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
            )
        }
        return nil
    }

    @ViewBuilder
    private func overdueChip(_ opener: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            opener()
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                Text(overdueCount == 1 ? "1 overdue" : "\(overdueCount) overdue")
                    .font(.caption.weight(.medium).monospacedDigit())
            }
            .foregroundStyle(skin.resolvedDestructiveColor)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .background(
                Capsule().fill(skin.resolvedDestructiveColor.opacity(DS.Opacity.subtleFill))
            )
        }
        .buttonStyle(.plain)
        .help("Open the fullscreen backlog to triage overdue tasks")
    }

    // MARK: - Helpers

    private var currentEvent: CalendarEvent? {
        events.first { $0.startDate <= now && $0.endDate > now }
    }

    private var nextEvent: CalendarEvent? {
        events
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    private func timeLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("H:mm")
        return fmt.string(from: date)
    }

    private func truncate(_ s: String, _ limit: Int) -> String {
        s.count > limit ? String(s.prefix(limit)) + "\u{2026}" : s
    }
}
