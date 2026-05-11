import XCTest
@testable import Bubo

/// End-to-end coverage for the `.focusBurst` intent: title composition,
/// phase-label alerts, `pomodoroTaskSequence` on `CalendarEvent`, and
/// persistence roundtrip.
@MainActor
final class FocusBurstTests: XCTestCase {

    // MARK: Intent label

    func testFocusBurstLabelReflectsMaxTasksAndContext() {
        XCTAssertEqual(
            ScheduleIntent.focusBurst(maxTasks: 4, contextFilter: nil).label,
            "Focus burst · 4 tasks"
        )
        XCTAssertEqual(
            ScheduleIntent.focusBurst(maxTasks: 3, contextFilter: "backend").label,
            "Focus burst · backend · 3 tasks"
        )
    }

    // MARK: Persistence roundtrip

    func testCalendarEventCarriesTaskSequenceThroughJSON() throws {
        var event = CalendarEvent(
            id: "burst-1",
            title: "Sprint",
            startDate: Date(),
            endDate: Date().addingTimeInterval(7800),
            location: nil, description: nil, calendarName: nil,
            eventType: .pomodoro
        )
        event.pomodoroConfig = PomodoroConfig(
            workMinutes: 25, breakMinutes: 5, rounds: 3, longBreakMinutes: 0
        )
        event.pomodoroTaskSequence = [
            .init(taskId: "t1", title: "Task A"),
            .init(taskId: "t2", title: "Task B"),
            .init(taskId: "t3", title: "Task C"),
        ]

        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: encoded)
        XCTAssertEqual(decoded.pomodoroTaskSequence.count, 3)
        XCTAssertEqual(decoded.pomodoroTaskSequence[1].title, "Task B")
    }

    // MARK: Gene carries reserved ids

    func testScheduleGeneCarriesReservedTaskIds() {
        let gene = ScheduleGene(
            eventId: "burst",
            title: "Sprint",
            startTime: Date(),
            duration: 7800,
            context: nil,
            energyCost: 0.5,
            priority: 0.8,
            isFocusBlock: true,
            pomodoroConfig: PomodoroConfig(
                workMinutes: 25, breakMinutes: 5, rounds: 3, longBreakMinutes: 0
            ),
            reservedTaskIds: ["t1", "t2", "t3"]
        )
        let shifted = gene.withStartTime(Date().addingTimeInterval(3600))
        XCTAssertEqual(shifted.reservedTaskIds, ["t1", "t2", "t3"])
    }

    // MARK: Phase alerts with task titles

    func testPhaseAlertsUseTaskTitlesWhenSequencePresent() {
        let scheduler = NotificationScheduler(settings: ReminderSettings())
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        var event = CalendarEvent(
            id: "burst",
            title: "Sprint",
            startDate: start,
            endDate: start.addingTimeInterval(TimeInterval(55 * 60)),
            location: nil, description: nil, calendarName: nil,
            eventType: .pomodoro
        )
        event.pomodoroConfig = PomodoroConfig(
            workMinutes: 25, breakMinutes: 5, rounds: 2, longBreakMinutes: 0
        )
        event.pomodoroTaskSequence = [
            .init(taskId: "t1", title: "Fix auth"),
            .init(taskId: "t2", title: "Write tests"),
        ]
        let alerts = scheduler.pomodoroPhaseAlerts(for: event)

        // Round 1 done → uses task title in quotes.
        XCTAssertEqual(alerts[0].title, "\u{201C}Fix auth\u{201D} done")
        // Break over → "Next: <round 2 title>"
        XCTAssertEqual(alerts[1].body, "Next: Write tests")
        // Session complete still uses event title (burst composite).
        XCTAssertEqual(alerts.last?.title, "Session complete")
    }

    // MARK: Current-task lookup from a phase

    func testSequenceIndexMatchesWorkRound() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        var event = CalendarEvent(
            id: "b", title: "Sprint",
            startDate: start,
            endDate: start.addingTimeInterval(TimeInterval(55 * 60)),
            location: nil, description: nil, calendarName: nil,
            eventType: .pomodoro
        )
        event.pomodoroConfig = PomodoroConfig(
            workMinutes: 25, breakMinutes: 5, rounds: 2, longBreakMinutes: 0
        )
        event.pomodoroTaskSequence = [
            .init(taskId: "t1", title: "A"),
            .init(taskId: "t2", title: "B"),
        ]

        // Mid-round-1 → work(1, 2); pomodoroTaskSequence[0] should map.
        let phase1 = event.currentPomodoroPhase(at: start.addingTimeInterval(60))!
        if case .work(let r, _) = phase1.kind {
            XCTAssertEqual(event.pomodoroTaskSequence[r - 1].title, "A")
        } else {
            XCTFail("expected work phase, got \(phase1.kind)")
        }

        // Mid-round-2 → work(2, 2); pomodoroTaskSequence[1] should map.
        let phase2 = event.currentPomodoroPhase(at: start.addingTimeInterval(31 * 60))!
        if case .work(let r, _) = phase2.kind {
            XCTAssertEqual(event.pomodoroTaskSequence[r - 1].title, "B")
        } else {
            XCTFail("expected work phase, got \(phase2.kind)")
        }
    }
}
