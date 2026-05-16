import SwiftUI
import BuboDomain

/// Stack of 0–2 Now-zone cards rendered between the energy ribbon and
/// the timeline. Card variants are derived once via `NowZoneState`;
/// this view owns layout and per-card action wiring.
struct NowZoneView: View {

    let cards: [NowZoneCard]

    let onJoinMeeting: (CalendarEvent) -> Void
    let onAcceptOverflow: () -> Void
    let onShowOverflowAlternatives: () -> Void
    let onStartFreeSlotTask: () -> Void
    let onOpenEvent: (CalendarEvent) -> Void

    @Environment(\.activeSkin) private var skin

    var body: some View {
        if cards.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 6) {
                ForEach(cards) { card in
                    cardView(for: card)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, DS.Spacing.contentMargin)
            .padding(.vertical, 4)
            .animation(DS.Animation.smoothSpring, value: cards.map(\.id))
        }
    }

    // MARK: - Card variants

    @ViewBuilder
    private func cardView(for card: NowZoneCard) -> some View {
        switch card {
        case .inMeeting(let event, let remaining):
            inMeetingCard(event: event, remainingMinutes: remaining)
        case .nextMeetingSoon(let event, let startsIn):
            soonCard(event: event, startsInMinutes: startsIn)
        case .overflowProposal(let title, let label):
            overflowCard(title: title, proposalLabel: label)
        case .freeSlotWithProposal(let minutes, let title):
            freeSlotCard(slotMinutes: minutes, taskTitle: title)
        }
    }

    @ViewBuilder
    private func inMeetingCard(event: CalendarEvent, remainingMinutes: Int) -> some View {
        cardShell(accent: skin.resolvedDestructiveColor) {
            HStack(spacing: DS.Spacing.sm) {
                liveDot
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(DS.Typography.body(skin: skin, weight: .semibold))
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .lineLimit(1)
                    Text(remainingMinutes <= 0
                         ? "Ends now"
                         : "\(remainingMinutes)\u{00A0}min left")
                        .font(DS.Typography.metric(skin: skin))
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
                Spacer(minLength: DS.Spacing.xs)
                if event.meetingLink != nil {
                    joinButton { onJoinMeeting(event) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpenEvent(event) }
        }
        .accessibilityLabel("\(event.title), \(remainingMinutes) minutes remaining")
    }

    @ViewBuilder
    private func soonCard(event: CalendarEvent, startsInMinutes: Int) -> some View {
        cardShell(accent: skin.accentColor) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(skin.accentColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(DS.Typography.body(skin: skin, weight: .semibold))
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .lineLimit(1)
                    Text(startsInMinutes <= 0
                         ? "Starts now"
                         : "Starts in\u{00A0}\(startsInMinutes)\u{00A0}min")
                        .font(DS.Typography.metric(skin: skin))
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
                Spacer(minLength: DS.Spacing.xs)
                if event.meetingLink != nil {
                    joinButton { onJoinMeeting(event) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpenEvent(event) }
        }
        .accessibilityLabel("\(event.title), starts in \(startsInMinutes) minutes")
    }

    @ViewBuilder
    private func overflowCard(title: String, proposalLabel: String) -> some View {
        cardShell(accent: skin.resolvedWarningColor) {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(skin.resolvedWarningColor)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(DS.Typography.body(skin: skin, weight: .semibold))
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .lineLimit(1)
                    Text(proposalLabel)
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .lineLimit(1)
                    HStack(spacing: DS.Spacing.xs) {
                        compactButton("Accept", systemImage: "checkmark", isPrimary: true) {
                            onAcceptOverflow()
                        }
                        compactButton("Alternatives", systemImage: nil, isPrimary: false) {
                            onShowOverflowAlternatives()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityLabel("\(title) doesn't fit today. \(proposalLabel)")
    }

    @ViewBuilder
    private func freeSlotCard(slotMinutes: Int, taskTitle: String) -> some View {
        cardShell(accent: skin.accentColor) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(skin.accentColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free \(slotMinutes)\u{00A0}min · \u{201C}\(taskTitle)\u{201D} fits")
                        .font(DS.Typography.body(skin: skin, weight: .regular))
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .lineLimit(1)
                    Text("Start Pomodoro now")
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
                Spacer(minLength: DS.Spacing.xs)
                compactButton("Start", systemImage: "play.fill", isPrimary: true) {
                    onStartFreeSlotTask()
                }
            }
        }
        .accessibilityLabel("Free \(slotMinutes) minutes. \(taskTitle) fits. Tap Start to begin Pomodoro.")
    }

    // MARK: - Shared chrome

    @ViewBuilder
    private func cardShell<C: View>(accent: Color, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.vertical, DS.Spacing.sm)
            .padding(.horizontal, DS.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                    .fill(skin.resolvedTextPrimary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                    .strokeBorder(accent.opacity(0.18), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var liveDot: some View {
        Circle()
            .fill(skin.resolvedDestructiveColor)
            .frame(width: 8, height: 8)
            .frame(width: 18)
    }

    @ViewBuilder
    private func joinButton(_ action: @escaping () -> Void) -> some View {
        Button(action: {
            Haptics.tap()
            action()
        }) {
            HStack(spacing: 4) {
                Image(systemName: "video.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Join")
                    .font(DS.Typography.subhead(skin: skin, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous).fill(skin.accentColor)
            )
        }
        .buttonStyle(.plain)
        .help("Join meeting")
    }

    @ViewBuilder
    private func compactButton(
        _ label: String,
        systemImage: String?,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            Haptics.tap()
            action()
        }) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(label)
                    .font(DS.Typography.subhead(skin: skin, weight: .semibold))
            }
            .foregroundStyle(isPrimary ? Color.white : skin.resolvedTextPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(isPrimary
                        ? skin.accentColor
                        : skin.resolvedTextPrimary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview {
    let now = Date()
    let cal = Calendar.current
    let upcomingStart = cal.date(byAdding: .minute, value: 7, to: now) ?? now
    let upcomingEnd = cal.date(byAdding: .minute, value: 30, to: upcomingStart) ?? upcomingStart
    let sample = CalendarEvent(
        id: "p1",
        title: "Design review",
        startDate: upcomingStart,
        endDate: upcomingEnd,
        eventType: .standard
    )
    return VStack(spacing: 12) {
        NowZoneView(
            cards: [
                .nextMeetingSoon(event: sample, startsInMinutes: 7),
                .overflowProposal(taskTitle: "Draft Q3 doc", proposalLabel: "Move to Mon 10:00")
            ],
            onJoinMeeting: { _ in },
            onAcceptOverflow: {},
            onShowOverflowAlternatives: {},
            onStartFreeSlotTask: {},
            onOpenEvent: { _ in }
        )
        NowZoneView(
            cards: [.freeSlotWithProposal(slotMinutes: 45, taskTitle: "Code review PR #221")],
            onJoinMeeting: { _ in },
            onAcceptOverflow: {},
            onShowOverflowAlternatives: {},
            onStartFreeSlotTask: {},
            onOpenEvent: { _ in }
        )
    }
    .frame(width: 360)
    .background(Color(white: 0.98))
}
#endif
