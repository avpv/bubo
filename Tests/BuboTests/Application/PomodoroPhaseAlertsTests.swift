import XCTest
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

/// Phase-boundary alerts piggy-back on `NotificationScheduler`'s existing
/// timer pipeline. These tests assert the generator produces the right
/// count, ordering, and titles for every shape of session.
@MainActor
final class PomodoroPhaseAlertsTests: XCTestCase {

    private func makeScheduler() -> NotificationScheduler {
        NotificationScheduler(settings: ReminderSettings())
    }

    private func event(
        start: Date, config: PomodoroConfig
    ) -> CalendarEvent {
        var e = CalendarEvent(
            id: "pom-test",
            title: "Focus",
            startDate: start,
            endDate: start.addingTimeInterval(TimeInterval(config.totalMinutes * 60)),
            location: nil, description: nil, calendarName: nil,
            eventType: .pomodoro
        )
        e.pomodoroConfig = config
        return e
    }

    // MARK: Count and ordering

    func testClassicSessionProducesWorkBreakAlertsPerRoundPlusFinish() {
        let scheduler = makeScheduler()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let config = PomodoroConfig(workMinutes: 25, breakMinutes: 5, rounds: 4, longBreakMinutes: 15)
        let alerts = scheduler.pomodoroPhaseAlerts(for: event(start: start, config: config))

        // 3 work-end + 3 break-end + allRoundsDone + sessionDone = 8.
        XCTAssertEqual(alerts.count, 8)

        // Monotonically increasing fire times.
        let dates = alerts.map(\.fireDate)
        XCTAssertEqual(dates, dates.sorted())
    }

    func testSingleRoundConfigProducesOnlySessionDone() {
        let scheduler = makeScheduler()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let config = PomodoroConfig(workMinutes: 25, breakMinutes: 5, rounds: 1, longBreakMinutes: 0)
        let alerts = scheduler.pomodoroPhaseAlerts(for: event(start: start, config: config))

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.title, "Session complete")
    }

    func testRoundsWithoutLongBreakSkipsLongBreakAlert() {
        let scheduler = makeScheduler()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let config = PomodoroConfig(workMinutes: 25, breakMinutes: 5, rounds: 3, longBreakMinutes: 0)
        let alerts = scheduler.pomodoroPhaseAlerts(for: event(start: start, config: config))

        // 2 work-end + 2 break-end + sessionDone = 5. No "all rounds" banner.
        XCTAssertEqual(alerts.count, 5)
        XCTAssertFalse(alerts.contains { $0.title == "All rounds done" })
        XCTAssertTrue(alerts.contains { $0.title == "Session complete" })
    }

    // MARK: Fire times align with phase boundaries

    func testFireTimesMatchCumulativeOffsets() {
        let scheduler = makeScheduler()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let config = PomodoroConfig(workMinutes: 25, breakMinutes: 5, rounds: 2, longBreakMinutes: 15)
        let alerts = scheduler.pomodoroPhaseAlerts(for: event(start: start, config: config))

        XCTAssertEqual(alerts[0].fireDate, start.addingTimeInterval(25 * 60))   // end of work 1
        XCTAssertEqual(alerts[1].fireDate, start.addingTimeInterval(30 * 60))   // end of break 1
        XCTAssertEqual(alerts[2].fireDate, start.addingTimeInterval(55 * 60))   // end of work 2 → "all rounds done"
        XCTAssertEqual(alerts[3].fireDate, start.addingTimeInterval(70 * 60))   // end of long break → "session complete"
    }

    // MARK: Titles & dedup keys

    func testTitlesReflectPhaseKind() {
        let scheduler = makeScheduler()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let config = PomodoroConfig(workMinutes: 25, breakMinutes: 5, rounds: 2, longBreakMinutes: 15)
        let alerts = scheduler.pomodoroPhaseAlerts(for: event(start: start, config: config))

        XCTAssertEqual(alerts[0].title, "Round 1 / 2 done")
        XCTAssertEqual(alerts[1].title, "Break over")
        XCTAssertEqual(alerts[2].title, "All rounds done")
        XCTAssertEqual(alerts[3].title, "Session complete")
    }

    func testDedupKeysAreUnique() {
        let scheduler = makeScheduler()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let config = PomodoroConfig(workMinutes: 25, breakMinutes: 5, rounds: 4, longBreakMinutes: 15)
        let alerts = scheduler.pomodoroPhaseAlerts(for: event(start: start, config: config))
        XCTAssertEqual(Set(alerts.map(\.key)).count, alerts.count)
    }

    // MARK: Non-config events

    func testNonPomodoroEventProducesNoAlerts() {
        let scheduler = makeScheduler()
        let e = CalendarEvent(
            id: "plain", title: "Meeting",
            startDate: Date(), endDate: Date().addingTimeInterval(3600),
            location: nil, description: nil, calendarName: nil,
            eventType: .standard
        )
        XCTAssertTrue(scheduler.pomodoroPhaseAlerts(for: e).isEmpty)
    }
}
