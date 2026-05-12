import XCTest
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - TaskListExpansion state machine tests
//
// Covers the chevron-driven state transitions that drive how many rows
// BacklogView renders. Pure-state assertions — no SwiftUI host — replace
// the snapshot-test suggestion from the improvement list with something
// the package can run today without pulling in swift-snapshot-testing.

final class TaskListExpansionTests: XCTestCase {

    func testNextCyclesCollapsedAndCompact() {
        // Two-state user-facing cycle: chevron toggles between «list
        // hidden» and «list visible». Full expansion moved into a separate
        // fullscreen Backlog (`BacklogFullscreenView`) — the third chevron
        // click is gone.
        XCTAssertEqual(TaskListExpansion.collapsed.next, .compact)
        XCTAssertEqual(TaskListExpansion.compact.next, .collapsed)
    }

    func testExpandedFallsBackToCollapsed() {
        // `.expanded` remains an internal state for the drag in BacklogView
        // (during dragging the list temporarily expands fully so that all
        // reorder target rows are visible). If for some reason it ends up
        // in `next`, the cycle must correctly return to `.collapsed`,
        // and not get stuck.
        XCTAssertEqual(TaskListExpansion.expanded.next, .collapsed)
    }

    func testIconsFollowDisclosureConvention() {
        // `.expanded` visually matches `.compact` — the user does not see the
        // chevron in this state (drag intercepts interaction), but it's
        // important that it does not flash a double arrow on an accidental
        // re-render.
        XCTAssertEqual(TaskListExpansion.collapsed.iconName, "chevron.right")
        XCTAssertEqual(TaskListExpansion.compact.iconName, "chevron.down")
        XCTAssertEqual(TaskListExpansion.expanded.iconName, "chevron.down")
    }

    func testAccessibilityHintDescribesNextState() {
        // Hint phrasing must reflect what happens on tap, not the current
        // state — VoiceOver reads the label, then the hint predicts the
        // outcome of activating the control.
        XCTAssertEqual(TaskListExpansion.collapsed.accessibilityHint, "Show tasks")
        XCTAssertEqual(TaskListExpansion.compact.accessibilityHint, "Hide tasks")
        XCTAssertEqual(TaskListExpansion.expanded.accessibilityHint, "Hide tasks")
    }
}
