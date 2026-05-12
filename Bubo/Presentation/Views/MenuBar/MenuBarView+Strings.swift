import SwiftUI
import BuboDomain

// MARK: - Computed Strings
//
// Pure-compute text properties used by the popover's header, day
// section meta, and empty states. Read only internal stored
// properties — no UI side effects, no mutation.

extension MenuBarView {

    /// Date for the popover header — «Tuesday, 6 May» (locale-aware via
    /// `DS.daySectionFormatter`). Reads `nowTick` so it rolls over at
    /// midnight without a manual refresh.
    var headerTitle: String {
        DS.daySectionFormatter.string(from: nowTick)
    }

    /// Quiet meta line under the date — count + next-event countdown,
    /// matching the design-system rhythm: «5 events · next in 5 h 18 min».
    /// Falls back to «No events today» when the day is empty and to
    /// «All N done» when nothing upcoming remains.
    var headerSubtitle: String {
        let cal = Calendar.current
        let now = nowTick
        guard let todayGroup = reminderService.eventsByDay.first(where: { cal.isDateInToday($0.date) }) else {
            return "No events today"
        }
        let todayEvents = todayGroup.events.filter { !reminderService.disintegratingEventIDs.contains($0.id) }
        let total = todayEvents.count
        guard total > 0 else { return "No events today" }

        let done = todayEvents.filter { $0.endDate <= now }.count

        let nextSuffix: String = {
            guard let next = todayEvents.first(where: { $0.startDate > now }) else { return "" }
            let mins = Int(next.startDate.timeIntervalSince(now)) / 60
            if mins < 1 { return " \u{00B7} now" }
            if mins < 60 { return " \u{00B7} next in\u{00A0}\(mins)\u{00A0}min" }
            let h = mins / 60
            let m = mins % 60
            if m == 0 { return " \u{00B7} next in\u{00A0}\(h)\u{00A0}h" }
            return " \u{00B7} next in\u{00A0}\(h)\u{00A0}h\u{00A0}\(m)\u{00A0}min"
        }()

        let countLabel: String
        if done == 0 {
            countLabel = total == 1 ? "1\u{00A0}event" : "\(total)\u{00A0}events"
        } else if done == total {
            countLabel = "All\u{00A0}\(total) done"
        } else {
            countLabel = "\(done)\u{00A0}of\u{00A0}\(total)"
        }
        return "\(countLabel)\(nextSuffix)"
    }

    /// Meta string for a per-day section header — quiet «next in 12 min»
    /// for today, nothing for past or future days. Suffix-only: the count
    /// badge already carries the event total, so the meta doesn't repeat
    /// it.
    func dayHeaderMeta(for events: [CalendarEvent], on date: Date) -> String? {
        let cal = Calendar.current
        guard cal.isDateInToday(date) else { return nil }

        let now = nowTick
        let visibleEvents = events.filter { !reminderService.disintegratingEventIDs.contains($0.id) }
        guard !visibleEvents.isEmpty else { return nil }

        guard let next = visibleEvents.first(where: { $0.startDate > now }) else {
            return "all done"
        }
        let mins = Int(next.startDate.timeIntervalSince(now)) / 60
        if mins < 1 { return "now" }
        if mins < 60 { return "next in\u{00A0}\(mins)\u{00A0}min" }
        let h = mins / 60
        let m = mins % 60
        if m == 0 { return "next in\u{00A0}\(h)\u{00A0}h" }
        return "next in\u{00A0}\(h)\u{00A0}h\u{00A0}\(m)\u{00A0}min"
    }

    /// Context-aware subtitle for the empty state.
    var emptyStateSubtitle: String {
        let cal = Calendar.current
        let now = Date()

        // Check if there are any future events across all days (including ones currently filtered out by the time window)
        let allUpcoming = reminderService.allEvents
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }

        if let next = allUpcoming.first {
            let interval = next.startDate.timeIntervalSince(now)
            let hours = Int(interval / 3600)
            let minutes = Int(interval / 60) % 60

            if cal.isDateInToday(next.startDate) {
                if hours > 0 {
                    return "Next: \(next.title) in\u{00A0}\(hours)\u{00A0}h\u{00A0}\(minutes)\u{00A0}min"
                }
                return "Next: \(next.title) in\u{00A0}\(minutes)\u{00A0}min"
            } else if cal.isDateInTomorrow(next.startDate) {
                let fmt = DateFormatter()
                fmt.dateFormat = "H:mm"
                return "Tomorrow: \(next.title) at\u{00A0}\(fmt.string(from: next.startDate))"
            } else {
                let fmt = DateFormatter()
                fmt.setLocalizedDateFormatFromTemplate("EEE")
                return "Next: \(next.title) on\u{00A0}\(fmt.string(from: next.startDate))"
            }
        }

        return "No upcoming events"
    }

    /// Empty-state copy when the active filter combo prunes everything.
    /// Keyed off whichever filter is the user's last action — matches the
    /// matching "clear filter" affordance shown alongside.
    var emptyFilteredStateMessage: String {
        switch freeSlotFilter {
        case .onlyFree: return "No free slots in working hours"
        case .hideFree: return "No events scheduled"
        case .all: return "No events with this color"
        }
    }

    /// Distinct color tags actually present in the next week of events.
    /// Drives the color filter bar so it only shows chips the user can
    /// actually pick (vs. the full `EventColorTag.allCases` palette).
    var usedColorTags: [EventColorTag] {
        let allEvents = reminderService.eventsByDay.flatMap(\.events)
        let usedTags = Set(allEvents.compactMap(\.colorTag))
        return EventColorTag.allCases.filter { usedTags.contains($0) }
    }
}
