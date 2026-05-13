import XCTest
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

final class TimelineSlotRankerTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)

    /// Reference «now» — Wed 2025-05-07 10:00 local. Fixed so deadline
    /// arithmetic is reproducible.
    private var now: Date {
        cal.date(from: DateComponents(year: 2025, month: 5, day: 7, hour: 10))!
    }

    /// Build a slot starting `hour:minute` after `now`'s day-start.
    private func slot(
        startHour: Int,
        startMinute: Int = 0,
        durationMinutes: Int,
        events: [CalendarEvent] = []
    ) -> TimelineSlotRanker.SlotContext {
        let dayStart = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .minute, value: startHour * 60 + startMinute, to: dayStart)!
        let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        return TimelineSlotRanker.SlotContext(start: start, end: end, adjacentEvents: events)
    }

    private func event(
        title: String,
        startHour: Int,
        durationMinutes: Int,
        context: String? = nil,
        calendarName: String? = nil
    ) -> CalendarEvent {
        let dayStart = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .minute, value: startHour * 60, to: dayStart)!
        return CalendarEvent(
            id: "ev-\(UUID().uuidString)",
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(TimeInterval(durationMinutes * 60)),
            location: nil,
            description: nil,
            calendarName: calendarName,
            eventType: .standard,
            colorTag: nil,
            context: context
        )
    }

    // MARK: - Urgency

    func testUrgentDeadlineBeatsRecency() {
        // Two tasks with no context, no period, no fit difference.
        // The urgent one (deadline tomorrow) must outrank the fresh one.
        let urgent = BacklogTask(
            id: "urgent",
            title: "Pay tax",
            durationMinutes: 30,
            deadline: cal.date(byAdding: .day, value: 1, to: now)!,
            createdAt: cal.date(byAdding: .day, value: -10, to: now)!
        )
        let fresh = BacklogTask(
            id: "fresh",
            title: "Refactor",
            durationMinutes: 30,
            createdAt: now
        )
        let ranked = TimelineSlotRanker.rank(
            tasks: [fresh, urgent],
            slot: slot(startHour: 11, durationMinutes: 30),
            now: now
        )
        XCTAssertEqual(ranked.first?.id, "urgent")
    }

    func testNoDeadlineScoresZeroUrgency() {
        let task = BacklogTask(id: "t", title: "x", durationMinutes: 30, createdAt: now)
        let s = TimelineSlotRanker.score(
            task,
            in: slot(startHour: 11, durationMinutes: 30),
            now: now
        )
        XCTAssertEqual(s.urgency, 0)
    }

    func testFarDeadlineGetsSoftTail() {
        let task = BacklogTask(
            id: "t",
            title: "x",
            durationMinutes: 30,
            deadline: cal.date(byAdding: .day, value: 5, to: now)!,
            createdAt: now
        )
        let s = TimelineSlotRanker.score(
            task,
            in: slot(startHour: 11, durationMinutes: 30),
            now: now
        )
        // Outside the urgent window (≤2d) but inside the soft tail.
        XCTAssertGreaterThan(s.urgency, 0)
        XCTAssertLessThan(s.urgency, 1)
    }

    // MARK: - Fit

    func testSnugFitOutranksTinyTaskInHugeSlot() {
        let snug = BacklogTask(id: "snug", title: "snug", durationMinutes: 90, createdAt: now)
        let tiny = BacklogTask(id: "tiny", title: "tiny", durationMinutes: 10, createdAt: now)
        let ranked = TimelineSlotRanker.rank(
            tasks: [tiny, snug],
            slot: slot(startHour: 11, durationMinutes: 100),
            now: now
        )
        XCTAssertEqual(ranked.first?.id, "snug")
    }

    func testOverflowIsPenalisedNotEliminated() {
        let task = BacklogTask(id: "big", title: "big", durationMinutes: 90, createdAt: now)
        let s = TimelineSlotRanker.score(
            task,
            in: slot(startHour: 11, durationMinutes: 60),
            now: now
        )
        // 50% overflow → still > 0, but small.
        XCTAssertGreaterThan(s.fit, 0)
        XCTAssertLessThan(s.fit, 0.3)
    }

    // MARK: - Context match

    func testTaskMatchingNeighbouringProjectWins() {
        // Slot is sandwiched between two Project X meetings.
        let neighbours = [
            event(title: "PX standup", startHour: 9, durationMinutes: 30, context: "Project X"),
            event(title: "PX review", startHour: 12, durationMinutes: 30, context: "Project X"),
        ]
        let projectX = BacklogTask(
            id: "px",
            title: "PX work",
            durationMinutes: 60,
            context: "Project X",
            createdAt: now
        )
        let other = BacklogTask(
            id: "other",
            title: "Personal",
            durationMinutes: 60,
            context: "Personal",
            createdAt: now
        )
        let ranked = TimelineSlotRanker.rank(
            tasks: [other, projectX],
            slot: slot(startHour: 10, startMinute: 30, durationMinutes: 60, events: neighbours),
            now: now
        )
        XCTAssertEqual(ranked.first?.id, "px")
    }

    func testContextMatchFallsBackToCalendarName() {
        // Event has no `context` but calendarName matches.
        let neighbours = [
            event(title: "Sync", startHour: 9, durationMinutes: 30, calendarName: "Project X")
        ]
        let task = BacklogTask(
            id: "t",
            title: "PX work",
            durationMinutes: 30,
            context: "Project X",
            createdAt: now
        )
        let s = TimelineSlotRanker.score(
            task,
            in: slot(startHour: 10, durationMinutes: 30, events: neighbours),
            now: now
        )
        XCTAssertGreaterThan(s.context, 0)
    }

    func testContextScoreZeroWhenNeighboursOutsideWindow() {
        // Event is 4h before slot — outside the 2h adjacency window.
        let neighbours = [
            event(title: "Distant", startHour: 6, durationMinutes: 30, context: "Project X")
        ]
        let task = BacklogTask(
            id: "t",
            title: "PX",
            durationMinutes: 30,
            context: "Project X",
            createdAt: now
        )
        let s = TimelineSlotRanker.score(
            task,
            in: slot(startHour: 11, durationMinutes: 30, events: neighbours),
            now: now
        )
        XCTAssertEqual(s.context, 0)
    }

    // MARK: - Period preference

    func testMorningTaskPrefersMorningSlot() {
        let task = BacklogTask(
            id: "m",
            title: "Morning",
            durationMinutes: 30,
            preferredPeriod: .morning,
            createdAt: now
        )
        let morning = TimelineSlotRanker.score(
            task,
            in: slot(startHour: 9, durationMinutes: 30),
            now: now
        )
        let evening = TimelineSlotRanker.score(
            task,
            in: slot(startHour: 20, durationMinutes: 30),
            now: now
        )
        XCTAssertGreaterThan(morning.period, evening.period)
    }

    // MARK: - Recency

    func testFreshTaskOutranksStaleAtEqualOtherwise() {
        let stale = BacklogTask(
            id: "stale",
            title: "old",
            durationMinutes: 30,
            createdAt: cal.date(byAdding: .day, value: -30, to: now)!
        )
        let fresh = BacklogTask(
            id: "fresh",
            title: "new",
            durationMinutes: 30,
            createdAt: now
        )
        let ranked = TimelineSlotRanker.rank(
            tasks: [stale, fresh],
            slot: slot(startHour: 11, durationMinutes: 30),
            now: now
        )
        XCTAssertEqual(ranked.first?.id, "fresh")
    }

    // MARK: - Defensive

    func testDoneTaskGetsZeroUrgencyEvenWithDeadline() {
        var task = BacklogTask(
            id: "done",
            title: "x",
            durationMinutes: 30,
            deadline: now,
            createdAt: now
        )
        task.status = .done
        let s = TimelineSlotRanker.score(
            task,
            in: slot(startHour: 11, durationMinutes: 30),
            now: now
        )
        XCTAssertEqual(s.urgency, 0)
    }

    func testEmptyInputReturnsEmpty() {
        let ranked = TimelineSlotRanker.rank(
            tasks: [],
            slot: slot(startHour: 11, durationMinutes: 30),
            now: now
        )
        XCTAssertTrue(ranked.isEmpty)
    }
}
