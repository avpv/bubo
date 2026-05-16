import Foundation
import BuboDomain

/// Single Now-zone card payload — the visual layer is `NowZoneView`,
/// the derivation is `NowZoneState.derive(...)`. Cards are ordered by
/// time-criticality on the layout side (meeting-anchored first,
/// schedule-state second).
enum NowZoneCard: Equatable, Identifiable {

    /// User is inside an event right now. Drives a live remaining-time
    /// chip and an optional join button when the event carries a
    /// videoconference URL.
    case inMeeting(event: CalendarEvent, remainingMinutes: Int)

    /// Next meeting starts within the «soon» horizon (≤ 10 min). Carries
    /// a countdown and a join affordance when available.
    case nextMeetingSoon(event: CalendarEvent, startsInMinutes: Int)

    /// Workload won't fit in today's remaining working window — surface
    /// the top overflowing task name and the optimizer's proposed
    /// destination (e.g. «move to tomorrow 10:00»). Wired to the
    /// Accept/Alternatives buttons in the card.
    case overflowProposal(taskTitle: String, proposalLabel: String)

    /// Sizeable free slot is open right now (or starts within 5 min) and
    /// the backlog has a candidate that fits — invite the user to start
    /// a Pomodoro on it. Lightest-touch nudge of the four.
    case freeSlotWithProposal(slotMinutes: Int, taskTitle: String)

    var id: String {
        switch self {
        case .inMeeting(let e, _):              return "inMeeting:\(e.id)"
        case .nextMeetingSoon(let e, _):        return "nextMeetingSoon:\(e.id)"
        case .overflowProposal(let t, _):       return "overflow:\(t)"
        case .freeSlotWithProposal(_, let t):   return "freeSlot:\(t)"
        }
    }

    /// Sort key — lower wins higher in the stack. Time-anchored states
    /// pre-empt schedule-state suggestions.
    var priority: Int {
        switch self {
        case .nextMeetingSoon: return 0
        case .inMeeting:       return 1
        case .overflowProposal: return 2
        case .freeSlotWithProposal: return 3
        }
    }
}

enum NowZoneState {

    /// Pure function — given today's input snapshot, returns 0…2 cards
    /// ordered by priority. The view stacks them top-to-bottom. Mutual
    /// exclusion: `freeSlotWithProposal` is suppressed when an overflow
    /// proposal exists (logically contradictory — can't both have an
    /// open slot and overflowing tasks).
    static func derive(
        now: Date,
        todayEvents: [CalendarEvent],
        pendingBacklogTitle: String?,
        pendingBacklogMinutes: Int?,
        unscheduledMinutes: Int,
        remainingWorkingMinutes: Int,
        workingHours: ClosedRange<Int>,
        soonHorizonMinutes: Int = 10,
        freeSlotMinHorizonMinutes: Int = 5,
        freeSlotMinDurationMinutes: Int = 25
    ) -> [NowZoneCard] {
        var cards: [NowZoneCard] = []

        if let live = todayEvents.first(where: { $0.startDate <= now && $0.endDate > now }) {
            let remaining = max(0, Int(live.endDate.timeIntervalSince(now) / 60))
            cards.append(.inMeeting(event: live, remainingMinutes: remaining))
        }

        if let next = todayEvents
            .filter({ $0.startDate > now })
            .min(by: { $0.startDate < $1.startDate }) {
            let minutes = Int(next.startDate.timeIntervalSince(now) / 60)
            if minutes <= soonHorizonMinutes {
                cards.append(.nextMeetingSoon(event: next, startsInMinutes: max(0, minutes)))
            }
        }

        let overflow = unscheduledMinutes > remainingWorkingMinutes
            && remainingWorkingMinutes >= 0
            && unscheduledMinutes > 0

        if overflow, let title = pendingBacklogTitle {
            cards.append(.overflowProposal(
                taskTitle: title,
                proposalLabel: defaultProposalLabel(for: now, workingHours: workingHours)
            ))
        } else if let title = pendingBacklogTitle,
                  let mins = pendingBacklogMinutes,
                  let slot = nextFreeSlot(
                      now: now,
                      todayEvents: todayEvents,
                      workingHours: workingHours,
                      horizonMinutes: freeSlotMinHorizonMinutes,
                      minimumMinutes: freeSlotMinDurationMinutes
                  ),
                  mins <= slot.minutes {
            cards.append(.freeSlotWithProposal(slotMinutes: slot.minutes, taskTitle: title))
        }

        return Array(cards.sorted { $0.priority < $1.priority }.prefix(2))
    }

    private static func defaultProposalLabel(
        for now: Date,
        workingHours: ClosedRange<Int>
    ) -> String {
        let cal = Calendar.current
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
              let proposed = cal.date(
                bySettingHour: workingHours.lowerBound + 1,
                minute: 0,
                second: 0,
                of: tomorrow
              ) else {
            return "Move to next workday"
        }
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("EEE H:mm")
        return "Move to \(fmt.string(from: proposed))"
    }

    private static func nextFreeSlot(
        now: Date,
        todayEvents: [CalendarEvent],
        workingHours: ClosedRange<Int>,
        horizonMinutes: Int,
        minimumMinutes: Int
    ) -> (start: Date, end: Date, minutes: Int)? {
        let cal = Calendar.current
        guard let workEnd = cal.date(
            bySettingHour: workingHours.upperBound,
            minute: 0,
            second: 0,
            of: now
        ) else { return nil }

        let cursorStart = now
        let cursorHorizon = cursorStart.addingTimeInterval(TimeInterval(horizonMinutes * 60))

        let upcoming = todayEvents
            .filter { $0.endDate > cursorStart && $0.startDate < workEnd }
            .sorted { $0.startDate < $1.startDate }

        var cursor = cursorStart
        for event in upcoming {
            if event.startDate > cursor {
                let gapMinutes = Int(event.startDate.timeIntervalSince(cursor) / 60)
                if gapMinutes >= minimumMinutes, event.startDate >= cursorStart, cursor <= cursorHorizon {
                    return (start: cursor, end: event.startDate, minutes: gapMinutes)
                }
            }
            cursor = max(cursor, event.endDate)
        }
        if cursor < workEnd {
            let trailing = Int(workEnd.timeIntervalSince(cursor) / 60)
            if trailing >= minimumMinutes, cursor <= cursorHorizon {
                return (start: cursor, end: workEnd, minutes: trailing)
            }
        }
        return nil
    }
}
