import XCTest
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

@MainActor
final class PomodoroHistoryServiceTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "PomodoroHistoryServiceTests"

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    // MARK: Persistence

    func testRecordPersistsAcrossInstances() {
        let a = PomodoroHistoryService(defaults: defaults)
        a.record(sample(hour: 10))
        let b = PomodoroHistoryService(defaults: defaults)
        XCTAssertEqual(b.entries.count, 1)
    }

    // MARK: learnedConfig

    func testLearnedConfigReturnsNilBelowThreshold() {
        let svc = PomodoroHistoryService(defaults: defaults)
        // Only 2 completed → below the 3-entry minimum.
        svc.record(sample(hour: 10))
        svc.record(sample(hour: 10))
        XCTAssertNil(svc.learnedConfig(forHour: 10))
    }

    func testLearnedConfigComputesMedianAtSimilarHour() {
        let svc = PomodoroHistoryService(defaults: defaults)
        // Three completed sessions near hour 10 with identical shape.
        for _ in 0..<3 {
            svc.record(sample(hour: 10, config: PomodoroConfig(workMinutes: 30, breakMinutes: 5, rounds: 3, longBreakMinutes: 15)))
        }
        let learned = svc.learnedConfig(forHour: 10)
        XCTAssertEqual(learned, PomodoroConfig(workMinutes: 30, breakMinutes: 5, rounds: 3, longBreakMinutes: 15))
    }

    func testLearnedConfigIgnoresAbandonedSessions() {
        let svc = PomodoroHistoryService(defaults: defaults)
        for _ in 0..<3 {
            svc.record(sample(hour: 10, completed: false))
        }
        XCTAssertNil(svc.learnedConfig(forHour: 10))
    }

    func testLearnedConfigIgnoresFarHours() {
        let svc = PomodoroHistoryService(defaults: defaults)
        // All three at hour 18 — asking for hour 10 should miss the window.
        for _ in 0..<3 {
            svc.record(sample(hour: 18))
        }
        XCTAssertNil(svc.learnedConfig(forHour: 10, windowHours: 2))
    }

    // MARK: Rolling cap

    func testRollingCapDropsOldest() {
        let svc = PomodoroHistoryService(defaults: defaults)
        for i in 0..<250 {
            svc.record(sample(hour: (i % 12) + 6))
        }
        XCTAssertLessThanOrEqual(svc.entries.count, 200)
    }

    // MARK: Helpers

    private func sample(
        hour: Int,
        completed: Bool = true,
        config: PomodoroConfig = PomodoroConfig(
            workMinutes: 25, breakMinutes: 5, rounds: 4, longBreakMinutes: 15
        )
    ) -> PomodoroHistoryEntry {
        PomodoroHistoryEntry(
            startedAt: Date(),
            startHour: hour,
            config: config,
            actualMinutes: completed ? config.totalMinutes : config.totalMinutes / 3,
            completed: completed
        )
    }
}
