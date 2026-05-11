import Foundation

// MARK: - Task List Expansion

/// Two-state disclosure for the Tasks card.
///
/// - `.collapsed`: header only, list fully hidden.
/// - `.compact`: list shown with an upper bound (~4 rows), the rest behind
///   internal scroll. Preserves room for the timeline below the card.
///
/// «Full expansion without the timeline» no longer lives here — it became a
/// separate fullscreen Backlog (`BacklogFullscreenView`), which is pushed
/// onto the popover's navigation stack via `onEnterFullscreen`.
/// One chevron is responsible only for «list shown / list hidden» — without
/// a third mysterious state.
///
/// Birman: one chevron — one meaning; the fullscreen representation is a
/// separate affordance next to it, not a third click of the same button.
///
/// `.expanded` remains an internal state into which BacklogView temporarily
/// switches during a drag, so all reorder target rows are visible at once.
/// The user cannot reach this state through the UI.
enum TaskListExpansion: Equatable, Hashable {
    case collapsed
    case compact
    /// Internal-only: used during a drag in `BacklogView`. Not reachable
    /// through the chevron.
    case expanded

    /// Next state in the round-trip cycle. `.expanded` is not part of this —
    /// it is set programmatically during a drag and cleared back on drop.
    var next: TaskListExpansion {
        switch self {
        case .collapsed: return .compact
        case .compact:   return .collapsed
        case .expanded:  return .collapsed
        }
    }

    /// SF Symbol for the disclosure chevron. `.expanded` visually matches
    /// `.compact` — the user doesn't see the chevron in that state, but
    /// the switch must be exhaustive.
    var iconName: String {
        switch self {
        case .collapsed:        return "chevron.right"
        case .compact, .expanded: return "chevron.down"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .collapsed:        return "Show tasks"
        case .compact, .expanded: return "Hide tasks"
        }
    }
}
