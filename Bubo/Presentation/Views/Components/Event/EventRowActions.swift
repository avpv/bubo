import SwiftUI
import BuboDomain

// MARK: - Event row actions
//
// Every verb an event row can fire, injected once through the
// environment instead of 17 closure parameters threaded through the
// host (PRINCIPLES §9; UI_REFACTORING.md stage 5). The menu-bar host
// builds one `EventRowActions` value capturing its services and
// installs it with `.environment(\.eventRowActions, …)`; all closures
// take the event, so a single value serves every row.
//
// All verbs are optional: nil hides the affordance (menu item, gesture,
// inline rename) exactly like the old nil-able callback parameters did.

struct EventRowActions {
    /// Open the event detail (row tap / Return).
    var tap: ((CalendarEvent) -> Void)? = nil
    var edit: ((CalendarEvent) -> Void)? = nil
    var delete: ((CalendarEvent) -> Void)? = nil
    var deleteOccurrence: ((CalendarEvent) -> Void)? = nil
    var deleteSeries: ((CalendarEvent) -> Void)? = nil
    /// Hide an external (Apple Calendar) occurrence from Bubo. The event
    /// stays in the calendar untouched — Bubo stops showing it. Escape
    /// hatch for ghost events a broken remote account never deletes from
    /// the local EventKit database.
    var hideExternal: ((CalendarEvent) -> Void)? = nil
    /// Hide every occurrence of an external recurring series.
    var hideExternalSeries: ((CalendarEvent) -> Void)? = nil
    /// Inline rename for local (Bubo-owned) events — fires with a
    /// trimmed, non-empty title that differs from the current one.
    var renameLocal: ((CalendarEvent, String) -> Void)? = nil
    /// Drag-to-reschedule: signed minute delta (negative = earlier).
    var reschedule: ((CalendarEvent, Int) -> Void)? = nil
    var completeTask: ((CalendarEvent) -> Void)? = nil

    // Optimizer context-menu verbs.
    var findBetterTime: ((CalendarEvent) -> Void)? = nil
    var splitTask: ((CalendarEvent) -> Void)? = nil
    var protectBlock: ((CalendarEvent) -> Void)? = nil
    var addPrep: ((CalendarEvent) -> Void)? = nil
    /// One-tap prep buffer of fixed minutes (5/10/15/30 sub-menu).
    var addPrepQuick: ((CalendarEvent, Int) -> Void)? = nil
    var convertToPomodoro: ((CalendarEvent) -> Void)? = nil
    /// Clone this event's shape as a fresh draft («Repeat from this…»).
    var repeatLikeThis: ((CalendarEvent) -> Void)? = nil
    /// Pin in place — optimizer keeps the event fixed (`.keepFixed`).
    var toggleLock: ((CalendarEvent) -> Void)? = nil
    /// Hide from the optimizer entirely (`.exclude`).
    var toggleExclude: ((CalendarEvent) -> Void)? = nil
}

private struct EventRowActionsKey: EnvironmentKey {
    static let defaultValue = EventRowActions()
}

extension EnvironmentValues {
    /// Verbs for event rows. Defaults to inert nils so previews and
    /// read-only contexts render rows without wiring.
    var eventRowActions: EventRowActions {
        get { self[EventRowActionsKey.self] }
        set { self[EventRowActionsKey.self] = newValue }
    }
}
