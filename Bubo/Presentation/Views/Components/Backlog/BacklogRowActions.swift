import SwiftUI
import BuboDomain
import BuboOptimizer

// MARK: - Backlog row actions
//
// Every verb a backlog row can fire, injected once through the
// environment instead of being threaded as ~20 closure parameters
// through every layer between the screen and the row. The screen
// builds one `BacklogRowActions` value capturing its own mutation
// helpers and installs it with `.environment(\.backlogRowActions, …)`;
// rows read it and pass the task to the verb.
//
// Adding a verb = one field here + one menu item in the row. No
// intermediate layer changes. (UI_REFACTORING.md, stage 1.)
//
// Convention: non-optional closures are verbs every backlog surface
// has; optional closures gate their affordance — nil hides the menu
// item / button exactly like the old nil-able callback parameters did.

struct BacklogRowActions {
    // Always-available verbs.
    var complete: (BacklogTask) -> Void = { _ in }
    var edit: (BacklogTask) -> Void = { _ in }
    var delete: (BacklogTask) -> Void = { _ in }
    var freeze: (BacklogTask) -> Void = { _ in }
    /// Another row was dropped onto `target` — reorder and/or context swap.
    var reorderDrop: (_ dropped: BacklogTaskDrag, _ target: BacklogTask) -> Void = { _, _ in }
    var moveUp: (BacklogTask) -> Void = { _ in }
    var moveDown: (BacklogTask) -> Void = { _ in }
    var moveToTop: (BacklogTask) -> Void = { _ in }
    var moveToBottom: (BacklogTask) -> Void = { _ in }
    /// Keyboard focus navigation relative to this row (plain ↑ / ↓).
    var focusPrevious: (BacklogTask) -> Void = { _ in }
    var focusNext: (BacklogTask) -> Void = { _ in }

    // Optional verbs — nil hides the affordance.
    /// «Find a slot now» — per-task scope optimizer run.
    var findSlot: ((BacklogTask) -> Void)? = nil
    /// Set / clear the task's preferred period (sub-menu).
    var setPreferredPeriod: ((BacklogTask, Period?) -> Void)? = nil
    /// «Split into shorter blocks» — `.splitLong` in scope of this task.
    var splitTask: ((BacklogTask) -> Void)? = nil
    /// Push the deadline forward by N days (sub-menu: 1 / 3 / 7).
    var snooze: ((BacklogTask, _ days: Int) -> Void)? = nil
    /// Open ⌘K seeded with this task.
    var reschedule: ((BacklogTask) -> Void)? = nil
    /// Open the inline deadline picker for this task.
    var setDeadline: ((BacklogTask) -> Void)? = nil
    /// Toggle the today-deadline urgency stripe.
    var toggleUrgent: ((BacklogTask) -> Void)? = nil
    /// ⌥-click on Schedule: preview N alternative slots without applying.
    var loadAlternatives: ((BacklogTask) async -> [ScheduleScenario])? = nil
    /// Commit one previewed alternative scenario.
    var pickAlternative: ((ScheduleScenario) -> Void)? = nil
    /// Toggle this row's membership in the multi-select set.
    var toggleSelection: ((BacklogTask) -> Void)? = nil
}

private struct BacklogRowActionsKey: EnvironmentKey {
    static let defaultValue = BacklogRowActions()
}

extension EnvironmentValues {
    /// Verbs for backlog rows. Defaults to inert no-ops so previews and
    /// read-only contexts can render rows without wiring.
    var backlogRowActions: BacklogRowActions {
        get { self[BacklogRowActionsKey.self] }
        set { self[BacklogRowActionsKey.self] = newValue }
    }
}
