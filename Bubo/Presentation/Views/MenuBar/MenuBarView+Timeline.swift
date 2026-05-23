import SwiftUI
import BuboDomain

// MARK: - Timeline Shaping
//
// Pure-compute helpers that turn `reminderService.allEvents` into the
// shape the popover's day list renders: a per-day bucket carrying
// events, free slots, ghost preview, and the NOW marker. Extracted
// from `MenuBarView.swift` so the main file is left with the view
// body and the SwiftUI subview builders.

extension MenuBarView {

    // MARK: - Filtered Events

    var filteredEventsByDay: [(date: Date, events: [CalendarEvent])] {
        let base: [(date: Date, events: [CalendarEvent])]
        if let filter = colorFilter {
            base = timelineEventsByDay.compactMap { dayGroup in
                let filtered = dayGroup.events.filter { $0.colorTag == filter }
                return filtered.isEmpty ? nil : (date: dayGroup.date, events: filtered)
            }
        } else {
            // Keep empty day groups so users can see their free slots and
            // drop tasks into days that have no events yet.
            base = timelineEventsByDay
        }
        return base
    }

    /// Day buckets the timeline actually renders — same shape as
    /// `reminderService.eventsByDay` but with a runtime-extendable
    /// horizon (`fetchWindowDays + extraDaysShown`). Other call sites
    /// (`headerSubtitle`, `isScrolledFromTop`, etc.) stay on the
    /// service's default 7-day window because they only care about
    /// today and the immediate horizon.
    var timelineEventsByDay: [(date: Date, events: [CalendarEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: reminderService.allEvents) { event in
            calendar.startOfDay(for: event.startDate)
        }
        let today = calendar.startOfDay(for: Date())
        let horizon = ReminderService.fetchWindowDays + extraDaysShown
        var results: [(date: Date, events: [CalendarEvent])] = []
        for offset in 0..<horizon {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            results.append((date: day, events: grouped[day] ?? []))
        }
        return results
    }

    /// Count of visible (non-disintegrating) events for a day group.
    func visibleEventCount(for events: [CalendarEvent]) -> Int {
        events.filter { !reminderService.disintegratingEventIDs.contains($0.id) }.count
    }

    /// Shape the raw filtered day list into the pre-computed
    /// `MenuBarTimelineDay` array consumed by `eventList`: per-day free
    /// slots, ghost placement, NOW marker, interleaving, plus the
    /// once-per-user drag-hint slot id (only the earliest day's first
    /// `.slot` row earns one, and only while the backlog has pending
    /// tasks). Pure function of `filteredEventsByDay` + the small set
    /// of state inputs the interleave needs; pulling it out of the
    /// view body keeps `eventList` declarative.
    func timelineDays() -> [MenuBarTimelineDay] {
        let backlogHasPending = !(optimizerService.backlogService?.pending.isEmpty ?? true)
        let days = filteredEventsByDay
        let firstDayDate = days.first?.date
        let shouldComputeFreeSlots = colorFilter == nil && freeSlotFilter != .hideFree
        let wh = optimizerService.workingHours
        return days.map { dayGroup -> MenuBarTimelineDay in
            let freeSlots: [(start: Date, end: Date)] = shouldComputeFreeSlots
                ? FreeSlotFinder.slots(
                    for: dayGroup.events,
                    on: dayGroup.date,
                    workingHours: wh
                )
                : []
            let ghost = ghostForDay(dayGroup.date)
            let interleaved = interleave(
                events: dayGroup.events,
                freeSlots: freeSlots,
                ghost: ghost,
                includeEvents: freeSlotFilter != .onlyFree
            )
            let showDragHint = backlogHasPending && dayGroup.date == firstDayDate
            let hintSlotId: String? = showDragHint
                ? interleaved.first(where: { if case .slot = $0 { return true } else { return false } })?.id
                : nil
            return MenuBarTimelineDay(
                date: dayGroup.date,
                events: dayGroup.events,
                items: interleaved,
                hintSlotId: hintSlotId
            )
        }
    }

    // MARK: - List Items (events + free slots interleaved)

    /// Interleaves events, free-slot pairs, and the optional ghost preview
    /// chronologically so the list reads top-to-bottom like a real timeline.
    func interleave(
        events: [CalendarEvent],
        freeSlots: [(start: Date, end: Date)],
        ghost: (start: Date, end: Date, title: String)? = nil,
        includeEvents: Bool = true
    ) -> [MenuBarDayListItem] {
        var result: [MenuBarDayListItem] = includeEvents ? events.map(MenuBarDayListItem.event) : []
        result += freeSlots.map { MenuBarDayListItem.slot($0.start, $0.end) }
        if let ghost {
            result.append(.ghost(ghost.start, ghost.end, ghost.title))
        }
        result.sort { startOf($0) < startOf($1) }
        return result
    }

    func startOf(_ item: MenuBarDayListItem) -> Date {
        switch item {
        case .event(let e): return e.startDate
        case .slot(let s, _): return s
        case .ghost(let s, _, _): return s
        }
    }

    /// Ghost payload for the given day, if the coordinator has one and its
    /// start date falls within this day. Returns nil otherwise so the row
    /// is only rendered under the day it actually belongs to.
    func ghostForDay(_ date: Date) -> (start: Date, end: Date, title: String)? {
        guard let slot = backlogCoordinator.ghostSlot,
              let title = backlogCoordinator.ghostTitle,
              !title.isEmpty,
              Calendar.current.isDate(slot.start, inSameDayAs: date) else {
            return nil
        }
        return (slot.start, slot.end, title)
    }
}
