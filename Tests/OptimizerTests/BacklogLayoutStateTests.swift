import XCTest
@testable import Bubo

// MARK: - TaskListExpansion state machine tests
//
// Covers the chevron-driven state transitions that drive how many rows
// BacklogView renders. Pure-state assertions — no SwiftUI host — replace
// the snapshot-test suggestion from the improvement list with something
// the package can run today without pulling in swift-snapshot-testing.

final class TaskListExpansionTests: XCTestCase {

    func testNextCyclesCollapsedCompactExpandedCollapsed() {
        XCTAssertEqual(TaskListExpansion.collapsed.next, .compact)
        XCTAssertEqual(TaskListExpansion.compact.next, .expanded)
        XCTAssertEqual(TaskListExpansion.expanded.next, .collapsed)
    }

    func testIconsFollowDisclosureConvention() {
        XCTAssertEqual(TaskListExpansion.collapsed.iconName, "chevron.right")
        XCTAssertEqual(TaskListExpansion.compact.iconName, "chevron.down")
        XCTAssertEqual(TaskListExpansion.expanded.iconName, "chevron.down.2")
    }

    func testAccessibilityHintDescribesNextState() {
        // Hint phrasing must reflect what happens on tap, not the current
        // state — VoiceOver reads the label, then the hint predicts the
        // outcome of activating the control.
        XCTAssertEqual(TaskListExpansion.collapsed.accessibilityHint, "Show tasks")
        XCTAssertEqual(TaskListExpansion.compact.accessibilityHint, "Show all tasks")
        XCTAssertEqual(TaskListExpansion.expanded.accessibilityHint, "Hide tasks")
    }
}
