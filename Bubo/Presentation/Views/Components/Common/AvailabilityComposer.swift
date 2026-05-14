import SwiftUI
import AppKit
import BuboDomain

// MARK: - Availability Composer
//
// S2 ("Don't show the chaos") gets one cheap, decisive fix: a Copy
// affordance that emits the next N free slots as plain text, ready to
// paste into Slack / Mail / iMessage. Closes the gap between Bubo's
// `FreeSlotFinder.slots(...)` (already implemented, well-tested) and
// the social moment "got a sec? when works for you?".
//
// The composer is a pure function; the host wires the menu item that
// triggers it (`FooterActions.copyAvailabilityMenuItem`). All formatting
// happens here so the wording stays consistent across surfaces.

enum AvailabilityComposer {

    /// One free slot in copy-ready form. Date and range strings are
    /// formatted with the user's locale, mono-friendly hour widths so
    /// the lines line up when the recipient sees them in a fixed-width
    /// chat font.
    struct Slot: Sendable, Equatable {
        let date: Date
        let start: Date
        let end: Date
    }

    /// Find up to `limit` upcoming free slots across the next
    /// `maxDaysAhead` working days, minimum length `minSlotMinutes`.
    /// Skips weekends when `workingDays` excludes them; honours
    /// `workingHours` exactly the same way `FreeSlotFinder.slots`
    /// does so the chip pile and the copy share one source of truth.
    static func nextSlots(
        in events: [CalendarEvent],
        workingHours: ClosedRange<Int>,
        workingDays: Set<Int>? = nil,
        limit: Int = 3,
        minSlotMinutes: Int = 30,
        maxDaysAhead: Int = 5,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [Slot] {
        var collected: [Slot] = []
        for dayOffset in 0...max(0, maxDaysAhead) {
            guard collected.count < limit else { break }
            guard let dayAnchor = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }

            // Honour workingDays — `Calendar.component(.weekday)` is
            // 1-based with Sunday = 1; we accept either convention by
            // matching against the supplied set as-is.
            if let workingDays {
                let weekday = calendar.component(.weekday, from: dayAnchor)
                guard workingDays.contains(weekday) else { continue }
            }

            let daySlots = FreeSlotFinder.slots(
                for: events,
                on: dayAnchor,
                workingHours: workingHours,
                minSlotMinutes: minSlotMinutes,
                calendar: calendar,
                now: now
            )

            for gap in daySlots {
                guard collected.count < limit else { break }
                collected.append(Slot(date: dayAnchor, start: gap.start, end: gap.end))
            }
        }
        return collected
    }

    /// Format a list of slots as plain text suitable for pasting into
    /// any chat / email field. One slot per line, day prefix on each:
    ///
    ///     Tue 14:00–15:00
    ///     Wed 10:30–11:30
    ///     Thu 16:00–17:00
    ///
    /// `header` is optional — when set, a leading line precedes the
    /// slot list. Default is `nil` so the caller controls phrasing.
    static func format(
        _ slots: [Slot],
        header: String? = nil,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        guard !slots.isEmpty else {
            return "No free slots in the next week."
        }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = locale
        dayFormatter.timeZone = timeZone
        dayFormatter.setLocalizedDateFormatFromTemplate("EEE d MMM")

        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.timeZone = timeZone
        timeFormatter.setLocalizedDateFormatFromTemplate("H:mm")

        var lines: [String] = []
        if let header { lines.append(header) }
        for slot in slots {
            let day = dayFormatter.string(from: slot.date)
            let start = timeFormatter.string(from: slot.start)
            let end = timeFormatter.string(from: slot.end)
            lines.append("\(day)  \(start)\u{2013}\(end)")
        }
        return lines.joined(separator: "\n")
    }

    /// One-shot helper used by the menu item: collect the next 3 free
    /// slots, format them, and place the result on the system
    /// pasteboard. Returns the line count so the host can flash a
    /// toast with feedback («Copied 3 free slots»).
    @discardableResult
    static func copyToPasteboard(
        events: [CalendarEvent],
        workingHours: ClosedRange<Int>,
        workingDays: Set<Int>? = nil,
        limit: Int = 3,
        minSlotMinutes: Int = 30
    ) -> Int {
        let slots = nextSlots(
            in: events,
            workingHours: workingHours,
            workingDays: workingDays,
            limit: limit,
            minSlotMinutes: minSlotMinutes
        )
        let text = format(slots)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return slots.count
    }
}
