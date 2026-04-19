import XCTest
@testable import Bubo

/// Tests for `CalendarEvent.currentPomodoroPhase(at:)` — the phase model
/// that drives the multi-round timer UI and the history outcome.
final class PomodoroPhaseTests: XCTestCase {

    private let config = PomodoroConfig(
        workMinutes: 25, breakMinutes: 5, rounds: 4, longBreakMinutes: 15
    )

    private func event(startingAt start: Date) -> CalendarEvent {
        var e = CalendarEvent(
            id: "p",
            title: "Pomodoro",
            startDate: start,
            endDate: start.addingTimeInterval(TimeInterval(config.totalMinutes * 60)),
            location: nil, description: nil, calendarName: nil,
            eventType: .pomodoro
        )
        e.pomodoroConfig = config
        return e
    }

    // MARK: Phase identification

    func testEarlyInRoundOneReturnsWorkOne() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let e = event(startingAt: start)
        let phase = e.currentPomodoroPhase(at: start.addingTimeInterval(60))!
        XCTAssertEqual(phase.kind, .work(round: 1, total: 4))
        XCTAssertEqual(phase.completedRounds, 0)
    }

    func testEndOfRoundOneReturnsWorkOneStillIfWithinWindow() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let e = event(startingAt: start)
        // 24 minutes into a 25-min work phase → still work round 1
        let phase = e.currentPomodoroPhase(at: start.addingTimeInterval(24 * 60))!
        XCTAssertEqual(phase.kind, .work(round: 1, total: 4))
    }

    func testEntersFirstBreakAtWorkEnd() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let e = event(startingAt: start)
        // Right at 25 min → first short break
        let phase = e.currentPomodoroPhase(at: start.addingTimeInterval(25 * 60))!
        XCTAssertEqual(phase.kind, .shortBreak(afterRound: 1))
        XCTAssertEqual(phase.completedRounds, 1)
    }

    func testRoundTwoStartsAfterFirstBreak() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let e = event(startingAt: start)
        // 30 min in → round 2
        let phase = e.currentPomodoroPhase(at: start.addingTimeInterval(30 * 60))!
        XCTAssertEqual(phase.kind, .work(round: 2, total: 4))
        XCTAssertEqual(phase.completedRounds, 1)
    }

    func testLongBreakAfterLastRound() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let e = event(startingAt: start)
        // After 4 work + 3 short breaks = 115 min → long break phase
        let phase = e.currentPomodoroPhase(at: start.addingTimeInterval(116 * 60))!
        XCTAssertEqual(phase.kind, .longBreak)
        XCTAssertEqual(phase.completedRounds, 4)
    }

    func testDoneAfterEverything() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let e = event(startingAt: start)
        // Way past the end
        let phase = e.currentPomodoroPhase(at: start.addingTimeInterval(200 * 60))!
        XCTAssertEqual(phase.kind, .done)
        XCTAssertEqual(phase.completedRounds, 4)
    }

    // MARK: Skipping long break when configured zero

    func testNoLongBreakSkipsToDoneAfterLastBreak() {
        var c = config
        c = PomodoroConfig(workMinutes: 25, breakMinutes: 5, rounds: 4, longBreakMinutes: 0)
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        var e = CalendarEvent(
            id: "p", title: "P", startDate: start,
            endDate: start.addingTimeInterval(TimeInterval(c.totalMinutes * 60)),
            location: nil, description: nil, calendarName: nil,
            eventType: .pomodoro
        )
        e.pomodoroConfig = c
        // Total without long break = 25*4 + 5*3 = 115 min. At 116 → done.
        let phase = e.currentPomodoroPhase(at: start.addingTimeInterval(116 * 60))!
        XCTAssertEqual(phase.kind, .done)
    }

    // MARK: Non-config events

    func testNonConfigEventReturnsNil() {
        let e = CalendarEvent(
            id: "plain", title: "Meeting",
            startDate: Date(), endDate: Date().addingTimeInterval(3600),
            location: nil, description: nil, calendarName: nil,
            eventType: .standard
        )
        XCTAssertNil(e.currentPomodoroPhase(at: Date()))
    }

    // MARK: Phase endpoints

    func testPhaseStartEndAlignsWithConfig() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let e = event(startingAt: start)
        let phase = e.currentPomodoroPhase(at: start.addingTimeInterval(10 * 60))!
        XCTAssertEqual(phase.phaseStart, start)
        XCTAssertEqual(phase.phaseEnd, start.addingTimeInterval(25 * 60))
        XCTAssertEqual(phase.duration, 25 * 60)
    }
}
