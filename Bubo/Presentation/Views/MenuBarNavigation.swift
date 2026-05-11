import Foundation

// MARK: - MenuBarNavigation

/// State-machine navigation for the menu-bar popover, replacing fragile
/// boolean flags. Lives at file scope (was nested inside `MenuBarView`
/// until 2026-05-11) so the type's surface is independent of the view
/// implementation. `Equatable` compares by event/task ID so a re-fetched
/// `CalendarEvent` with the same id doesn't trigger a navigation change.
enum MenuBarNavigation: Equatable {
    case list
    case detail(CalendarEvent)
    case addEvent(editing: CalendarEvent? = nil, initialType: EventType = .standard, prefillFrom: CalendarEvent? = nil)
    case editTask(BacklogTask)
    /// Compact creation form, opened from `+ Add task…` via Shift+Return
    /// or the trailing Details affordance. Pre-fills title + parsed
    /// duration so the user doesn't retype what they already typed.
    case newTask(prefillTitle: String, prefillDuration: Int?)
    case timer(CalendarEvent)
    case quickAddTasks
    case backlog

    var isTimer: Bool {
        if case .timer = self { return true }
        return false
    }

    static func == (lhs: MenuBarNavigation, rhs: MenuBarNavigation) -> Bool {
        switch (lhs, rhs) {
        case (.list, .list): return true
        case (.detail(let a), .detail(let b)): return a.id == b.id
        case (.addEvent(let a, let t1, let p1), .addEvent(let b, let t2, let p2)):
            return a?.id == b?.id && t1 == t2 && p1?.id == p2?.id
        case (.editTask(let a), .editTask(let b)): return a.id == b.id
        case (.newTask(let t1, let d1), .newTask(let t2, let d2)):
            return t1 == t2 && d1 == d2
        case (.timer(let a), .timer(let b)): return a.id == b.id
        case (.quickAddTasks, .quickAddTasks): return true
        case (.backlog, .backlog): return true
        default: return false
        }
    }
}
