import Foundation

// MARK: - MenuBarTimelineDay

/// One day's worth of pre-shaped data for the menu-bar timeline. Carries
/// the date, the day's raw events (still needed by the drag-mode
/// collapsed header), the interleaved item list (events + free slots +
/// optional ghost + optional NOW marker, chronologically sorted), and
/// the id of the slot that should display the drag-onboarding hint —
/// only the earliest day's first `.slot` item earns one, and only while
/// the backlog has something pending.
///
/// Lives at file scope so the timeline data shape is independent of the
/// view implementation. Built by `MenuBarView.timelineDays(...)` and
/// consumed by `MenuBarView.eventList` / `dayGroupSection`.
struct MenuBarTimelineDay: Identifiable {
    let date: Date
    let events: [CalendarEvent]
    let items: [MenuBarDayListItem]
    let hintSlotId: String?

    var id: Date { date }
}
