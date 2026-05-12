import Foundation
import BuboDomain

// MARK: - MenuBarPaletteContext

/// Context for the command-palette overlay hosted by `MenuBarView`.
/// `nil` on the parent's `@State paletteContext` means hidden; a
/// non-nil value carries any seed data the palette should preselect
/// (event, task, slot bounds, or recipe id). Lives at file scope (was
/// nested inside `MenuBarView` until 2026-05-11) so the type's surface
/// is independent of the view implementation.
struct MenuBarPaletteContext: Equatable {
    var seedEvent: CalendarEvent? = nil
    /// Per-task seed — set when the user opens the palette from a
    /// backlog row's right-click → «Reschedule…». Routes to the
    /// task-specific suggestions in `CommandPalette.suggestions`.
    var seedTask: BacklogTask? = nil
    var seedSlotMinutes: Int? = nil
    var seedSlotStart: Date? = nil
    var seedSlotEnd: Date? = nil
    var seedRecipeId: String? = nil
}
