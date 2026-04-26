import XCTest
@testable import Bubo

// MARK: - TaskListExpansion state machine tests
//
// Covers the chevron-driven state transitions that drive how many rows
// BacklogView renders. Pure-state assertions — no SwiftUI host — replace
// the snapshot-test suggestion from the improvement list with something
// the package can run today without pulling in swift-snapshot-testing.

final class TaskListExpansionTests: XCTestCase {

    func testNextCyclesCollapsedAndCompact() {
        // Two-state user-facing cycle: chevron toggles between «список
        // скрыт» и «список виден». Полное раскрытие переехало в отдельный
        // fullscreen-аффорданс (`SprintView`) — третий клик шеврона убран.
        XCTAssertEqual(TaskListExpansion.collapsed.next, .compact)
        XCTAssertEqual(TaskListExpansion.compact.next, .collapsed)
    }

    func testExpandedFallsBackToCollapsed() {
        // `.expanded` остаётся внутренним состоянием для drag'а в BacklogView
        // (на время перетаскивания список временно раскрывается полностью,
        // чтобы все строки-цели реордера были видны). Если оно почему-то
        // окажется в `next`, цикл должен корректно вернуть в `.collapsed`,
        // а не зависнуть.
        XCTAssertEqual(TaskListExpansion.expanded.next, .collapsed)
    }

    func testIconsFollowDisclosureConvention() {
        // `.expanded` визуально совпадает с `.compact` — пользователь шеврон
        // в этом состоянии не видит (drag перехватывает взаимодействие), но
        // нам важно, чтобы оно не светило двойной стрелкой при случайном
        // ререндере.
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
