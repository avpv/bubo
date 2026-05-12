import SwiftUI
import BuboDomain

// MARK: - Focus & Scroll Helpers
//
// State of the day-nav cluster in the header (which day is «focused»),
// plus the small handful of computed properties the popover header
// reads to decide what to show: backlog pending count, top-of-list
// detector for the «scroll to top» chevron, today's events sliced
// out for the Now/Next line. Pure compute apart from `navigateToDay`,
// which mutates `focusedDayDate` and drives the ScrollViewReader.

extension MenuBarView {

    /// Backlog pending count surfaced in the popover header's
    /// SmartActionsBar chip. Reads through the optimizer service so
    /// header + chip stay in sync without their own source of truth.
    var pendingTaskCount: Int {
        optimizerService.backlogService?.pending.count ?? 0
    }

    /// True when the user has scrolled below the first handful of
    /// events — drives the «back to top» chevron in the header so it
    /// only appears when there's somewhere to scroll back to.
    var isScrolledFromTop: Bool {
        guard let pos = scrollPositionID else { return false }
        let allEvents = reminderService.eventsByDay.flatMap(\.events)
        let topIDs = Set(allEvents.prefix(5).map(\.id))
        return !topIDs.contains(pos)
    }

    /// Index of the currently-focused day inside `filteredEventsByDay`,
    /// defaulting to today when the user hasn't navigated yet (or to
    /// the first day if today isn't in the window). Drives the
    /// enable/disable state of the day-nav arrows.
    var focusedDayIndex: Int {
        let days = filteredEventsByDay
        guard !days.isEmpty else { return 0 }
        let cal = Calendar.current
        let target = focusedDayDate
            ?? days.first(where: { cal.isDateInToday($0.date) })?.date
        if let target,
           let idx = days.firstIndex(where: { cal.isDate($0.date, inSameDayAs: target) }) {
            return idx
        }
        return 0
    }

    /// True when the day-nav cluster considers «today» the active
    /// focus — either the user hasn't navigated, or they've explicitly
    /// jumped back to today's section. Dims the Today button.
    var focusedDayIsToday: Bool {
        let cal = Calendar.current
        if let date = focusedDayDate {
            return cal.isDateInToday(date)
        }
        return true
    }

    /// Scroll the timeline to the day at `index`, clamped to the
    /// visible window, and update `focusedDayDate` so the nav cluster
    /// stays in sync. No-op on empty days.
    func navigateToDay(at index: Int, scroll: ScrollViewProxy) {
        let days = filteredEventsByDay
        guard !days.isEmpty else { return }
        let clamped = max(0, min(days.count - 1, index))
        let targetDate = days[clamped].date
        Haptics.tap()
        focusedDayDate = targetDate
        withAnimation(DS.Animation.smoothSpring) {
            scroll.scrollTo(targetDate, anchor: .top)
        }
    }

    /// Today's events used to compute the «Now / Next» line. Pulled
    /// from the same `eventsByDay` source the timeline reads, narrowed
    /// to the current calendar day.
    var todaysEventsForNowNext: [CalendarEvent] {
        let cal = Calendar.current
        return reminderService.eventsByDay
            .first(where: { cal.isDate($0.date, inSameDayAs: nowTick) })?
            .events ?? []
    }
}
