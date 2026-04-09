import XCTest
@testable import Bubo

final class BacklogTaskTests: XCTestCase {

    // MARK: - Task Creation

    func testDefaultTaskValues() {
        let task = BacklogTask(title: "Test")
        XCTAssertEqual(task.title, "Test")
        XCTAssertEqual(task.durationMinutes, 60)
        XCTAssertEqual(task.priority, .medium)
        XCTAssertEqual(task.status, .pending)
        XCTAssertNil(task.deadline)
        XCTAssertNil(task.storyPoints)
        XCTAssertNil(task.context)
        XCTAssertNil(task.scheduledEventId)
        XCTAssertTrue(task.dependsOn.isEmpty)
    }

    func testTaskWithAllProperties() {
        let deadline = Date().addingTimeInterval(86400)
        let task = BacklogTask(
            title: "Complex Task",
            durationMinutes: 120,
            priority: .high,
            deadline: deadline,
            storyPoints: 8,
            context: "Project X",
            dependsOn: ["dep-1", "dep-2"],
            preferredPeriod: .morning
        )
        XCTAssertEqual(task.durationMinutes, 120)
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.storyPoints, 8)
        XCTAssertEqual(task.context, "Project X")
        XCTAssertEqual(task.dependsOn, ["dep-1", "dep-2"])
        XCTAssertEqual(task.preferredPeriod, .morning)
    }

    // MARK: - Priority

    func testPriorityNumericValues() {
        XCTAssertEqual(TaskPriority.low.numericValue, 0.3)
        XCTAssertEqual(TaskPriority.medium.numericValue, 0.5)
        XCTAssertEqual(TaskPriority.high.numericValue, 0.9)
    }

    // MARK: - Conversion to OptimizableEvent

    func testToOptimizableEvent() {
        let task = BacklogTask(
            id: "task-1",
            title: "Write report",
            durationMinutes: 90,
            priority: .high,
            context: "Reports",
            preferredPeriod: .morning
        )
        let event = task.toOptimizableEvent()

        XCTAssertEqual(event.id, "task-1")
        XCTAssertEqual(event.title, "Write report")
        XCTAssertEqual(event.duration, 5400)  // 90 * 60
        XCTAssertEqual(event.priority, 0.9)
        XCTAssertEqual(event.context, "Reports")
        XCTAssertEqual(event.preferredHourRange, 6...12)  // morning
        XCTAssertFalse(event.isFocusBlock)
    }

    func testToOptimizableEventWithDeadline() {
        let deadline = Date().addingTimeInterval(86400)
        let task = BacklogTask(
            title: "Urgent",
            deadline: deadline,
            storyPoints: 5
        )
        let event = task.toOptimizableEvent()

        XCTAssertEqual(event.deadline, deadline)
        XCTAssertEqual(event.storyPoints, 5)
        // Energy should be adjusted for story points
        XCTAssertGreaterThan(event.energyCost, 0.3)
    }

    // MARK: - Codable

    func testTaskCodable() throws {
        let task = BacklogTask(
            title: "Codable Test",
            durationMinutes: 45,
            priority: .low,
            storyPoints: 3,
            context: "Testing"
        )
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(BacklogTask.self, from: data)

        XCTAssertEqual(decoded.title, task.title)
        XCTAssertEqual(decoded.durationMinutes, task.durationMinutes)
        XCTAssertEqual(decoded.priority, task.priority)
        XCTAssertEqual(decoded.storyPoints, task.storyPoints)
        XCTAssertEqual(decoded.context, task.context)
    }

    // MARK: - Adjusted Energy

    func testAdjustedEnergy() {
        // No story points → base energy unchanged
        XCTAssertEqual(adjustedEnergy(base: 0.5, storyPoints: nil), 0.5)
        XCTAssertEqual(adjustedEnergy(base: 0.5, storyPoints: 0), 0.5)

        // High story points → higher energy
        let highSP = adjustedEnergy(base: 0.5, storyPoints: 13)
        XCTAssertGreaterThan(highSP, 0.5)

        // Low story points → lower energy boost
        let lowSP = adjustedEnergy(base: 0.5, storyPoints: 1)
        XCTAssertLessThan(lowSP, highSP)
    }
}
