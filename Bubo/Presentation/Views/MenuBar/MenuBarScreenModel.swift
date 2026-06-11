import SwiftUI
import BuboDomain

// MARK: - Menu-bar screen model
//
// Stage 3 of UI_REFACTORING.md (first slice): the timeline/filter state
// and every pure derived computation of the main popover move off the
// view into one observable model. The remaining MenuBarView state
// (sync lifecycle, palette, toasts, quick capture) follows in the next
// slice — this one absorbs what `MenuBarView+Timeline`, `+Focus`, and
// `+Strings` used to compute against view-local `@State`.

@MainActor
@Observable
final class MenuBarScreenModel {

    // MARK: Dependencies

    @ObservationIgnored private let reminderService: ReminderService
    @ObservationIgnored private let optimizerService: OptimizerService
    /// Shared drag/ghost coordinator — the ghost row is part of the
    /// timeline shape, so the model needs to read it.
    @ObservationIgnored private let backlogCoordinator: BacklogInteractionCoordinator

    init(
        reminderService: ReminderService,
        optimizerService: OptimizerService,
        backlogCoordinator: BacklogInteractionCoordinator
    ) {
        self.reminderService = reminderService
        self.optimizerService = optimizerService
        self.backlogCoordinator = backlogCoordinator
    }

    // MARK: Filter & day-nav state

    /// Colour filter for the timeline; mutually exclusive with
    /// `freeSlotFilter` — picking either resets the other (the
    /// ColorFilterBar owns that rule).
    var colorFilter: EventColorTag? = nil
    /// Tri-state free-slot filter: `.all` → `.onlyFree` → `.hideFree`.
    var freeSlotFilter: FreeSlotFilter = .all

    /// Day anchored by the header's day-nav cluster. nil = «not
    /// navigated yet», treated as today for the Today button's state.
    var focusedDayDate: Date? = nil

    /// Extra days appended to the timeline horizon by «Load more days».
    /// Capped so LazyVStack content stays bounded.
    var extraDaysShown: Int = 0
    static let extraDaysCap: Int = 84

    /// Per-minute tick driving the «happening now» highlight and the
    /// header strings. Fed by the view's shared minute timer so every
    /// consumer reads one Date instead of owning a timer.
    var nowTick: Date = Date()

    /// Extend the horizon by one week, clamped to the cap.
    func loadMoreDays() {
        extraDaysShown = min(Self.extraDaysCap, extraDaysShown + 7)
    }

    func clearFilters() {
        colorFilter = nil
        freeSlotFilter = .all
    }

    /// Clamp + set the focused day; returns the date the view should
    /// scroll to (nil on an empty window). Scrolling itself stays on
    /// the view — ScrollViewProxy is view machinery.
    func focusDay(at index: Int) -> Date? {
        let days = filteredEventsByDay
        guard !days.isEmpty else { return nil }
        let clamped = max(0, min(days.count - 1, index))
        let targetDate = days[clamped].date
        focusedDayDate = targetDate
        return targetDate
    }

    // MARK: Derived — day-nav

    /// Backlog pending count surfaced in the popover's empty state.
    var pendingTaskCount: Int {
        optimizerService.backlogService?.pending.count ?? 0
    }

    /// Index of the focused day inside `filteredEventsByDay`, defaulting
    /// to today. Drives the enable/disable state of the day-nav arrows.
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

    /// True when the day-nav cluster considers «today» the active focus.
    var focusedDayIsToday: Bool {
        let cal = Calendar.current
        if let date = focusedDayDate {
            return cal.isDateInToday(date)
        }
        return true
    }

    // MARK: Derived — timeline shaping

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

    /// Day buckets the timeline renders — `reminderService.eventsByDay`
    /// shape with a runtime-extendable horizon.
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

    /// Shape the filtered day list into the pre-computed
    /// `MenuBarTimelineDay` array the event list consumes: per-day free
    /// slots, ghost placement, interleaving, and the once-per-user
    /// drag-hint slot id.
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

    /// Interleaves events, free-slot pairs, and the optional ghost preview
    /// chronologically so the list reads top-to-bottom like a timeline.
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

    /// Ghost payload for the given day, if the coordinator has one whose
    /// start falls within this day.
    func ghostForDay(_ date: Date) -> (start: Date, end: Date, title: String)? {
        guard let slot = backlogCoordinator.ghostSlot,
              let title = backlogCoordinator.ghostTitle,
              !title.isEmpty,
              Calendar.current.isDate(slot.start, inSameDayAs: date) else {
            return nil
        }
        return (slot.start, slot.end, title)
    }

    // MARK: Derived — strings

    /// Header date — «Tuesday, 6 May». Reads `nowTick` so it rolls over
    /// at midnight without a manual refresh.
    var headerTitle: String {
        DS.daySectionFormatter.string(from: nowTick)
    }

    /// Quiet meta line under the date — «5 events · next in 5 h 18 min»,
    /// «All N done», or «No events today».
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

    /// Per-day section header meta — «next in 12 min» for today only.
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
    var emptyFilteredStateMessage: String {
        switch freeSlotFilter {
        case .onlyFree: return "No free slots in working hours"
        case .hideFree: return "No events scheduled"
        case .all: return "No events with this color"
        }
    }
}
