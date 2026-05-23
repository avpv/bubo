import Foundation
import BuboDomain

// MARK: - MenuBarDayListItem

/// A row in the menu-bar day list — either a real event, an empty
/// free-slot, or the typed-ghost block that previews where a backlog
/// task would land.
///
/// Lives at file scope (was nested inside `MenuBarView.DayListItem`
/// until 2026-05-11) so the type's surface is independent of the view
/// implementation.
enum MenuBarDayListItem: Identifiable {
    case event(CalendarEvent)
    case slot(Date, Date)
    case ghost(Date, Date, String)

    var id: String {
        switch self {
        case .event(let e): return "event:\(e.id)"
        case .slot(let s, let e): return "slot:\(s.timeIntervalSinceReferenceDate)-\(e.timeIntervalSinceReferenceDate)"
        case .ghost(let s, let e, _): return "ghost:\(s.timeIntervalSinceReferenceDate)-\(e.timeIntervalSinceReferenceDate)"
        }
    }
}
