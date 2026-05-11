import Foundation

// MARK: - MenuBarDayListItem

/// A row in the menu-bar day list — either a real event, an empty
/// free-slot, the typed-ghost block that previews where a backlog task
/// would land, or the inline «NOW · 10:48» divider.
///
/// Lives at file scope (was nested inside `MenuBarView.DayListItem`
/// until 2026-05-11) so the type's surface is independent of the view
/// implementation.
enum MenuBarDayListItem: Identifiable {
    case event(CalendarEvent)
    case slot(Date, Date)
    case ghost(Date, Date, String)
    /// Inline «NOW · 10:48» divider, inserted into today's
    /// timeline at wall-clock position so the boundary between
    /// past and future events reads at a glance. Carries the
    /// timestamp so the label updates with `nowTick`.
    case nowMarker(Date)

    var id: String {
        switch self {
        case .event(let e): return "event:\(e.id)"
        case .slot(let s, let e): return "slot:\(s.timeIntervalSinceReferenceDate)-\(e.timeIntervalSinceReferenceDate)"
        case .ghost(let s, let e, _): return "ghost:\(s.timeIntervalSinceReferenceDate)-\(e.timeIntervalSinceReferenceDate)"
        case .nowMarker: return "now"
        }
    }
}
