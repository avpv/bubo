import XCTest
@testable import BuboDomain

// MARK: - RecurrenceExpander tests
//
// Pins the fixes from the 2026-07-16 core audit:
//   • monthly rules emit the seed month's own occurrence when the
//     start date precedes the rule's target (previously silently
//     skipped straight to the next interval month);
//   • pomodoro work rounds carry ordinal `_occ{N}` ids that
//     `CalendarEvent.pomodoroRoundNumber` / `pomodoroSessionBaseId`
//     can actually parse (the `_r{timestamp}` form displayed every
//     round as «round 1» and broke session grouping);
//   • EXDATE exclusion compares same-day, per its documented iCal
//     semantics, not exact-timestamp;
//   • `FREQ=MONTHLY;BYDAY=FR` (no ordinal, interval 1) maps to the
//     equivalent weekly rule instead of silently degrading to
//     «monthly on the start date's day».
//
// Dates are built with `Calendar.current` because the expander itself
// hardcodes it — building fixtures with any other calendar would test
// timezone drift, not the expansion logic.
final class RecurrenceExpanderTests: XCTestCase {

    private let cal = Calendar.current

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 10, _ minute: Int = 0
    ) -> Date {
        cal.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func event(
        id: String = "base",
        start: Date,
        minutes: Int,
        rule: RecurrenceRule,
        type: EventType = .standard
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: "Test",
            startDate: start,
            endDate: start.addingTimeInterval(TimeInterval(minutes * 60)),
            recurrenceRule: rule,
            eventType: type
        )
    }

    // MARK: Monthly seed month

    func testMonthlyDayOfMonthEmitsSeedMonthOccurrence() {
        // Seeded Jan 5 with BYMONTHDAY=15 — Jan 15 must be the first
        // occurrence, not Feb 15.
        let rule = RecurrenceRule(
            frequency: .monthly,
            end: .afterCount(2),
            monthlyMode: .dayOfMonth(15)
        )
        let occurrences = RecurrenceExpander.expand(
            event(start: date(2026, 1, 5), minutes: 60, rule: rule),
            windowEnd: date(2026, 6, 1)
        )
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertEqual(cal.component(.month, from: occurrences[0].startDate), 1)
        XCTAssertEqual(cal.component(.day, from: occurrences[0].startDate), 15)
        XCTAssertEqual(cal.component(.month, from: occurrences[1].startDate), 2)
        XCTAssertEqual(cal.component(.day, from: occurrences[1].startDate), 15)
    }

    func testMonthlyStartOnTargetDayDoesNotDuplicate() {
        // Seeded exactly ON the 15th: the seed itself is occurrence 1,
        // and the same-month fast path must not emit Jan 15 twice.
        let rule = RecurrenceRule(
            frequency: .monthly,
            end: .afterCount(2),
            monthlyMode: .dayOfMonth(15)
        )
        let occurrences = RecurrenceExpander.expand(
            event(start: date(2026, 1, 15), minutes: 60, rule: rule),
            windowEnd: date(2026, 6, 1)
        )
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertEqual(cal.component(.month, from: occurrences[0].startDate), 1)
        XCTAssertEqual(cal.component(.month, from: occurrences[1].startDate), 2)
    }

    // MARK: Pomodoro occurrence ids

    func testPomodoroWorkRoundsCarryOrdinalIds() {
        // 25m work on a 30m cadence × 3 rounds: work ids must follow
        // the `_occ{N}` scheme the CalendarEvent parsers understand.
        let rule = RecurrenceRule(
            frequency: .minutely,
            interval: 30,
            end: .afterCount(3),
            pomodoroMode: true
        )
        let start = date(2026, 7, 6, 9)
        let occurrences = RecurrenceExpander.expand(
            event(id: "pomo", start: start, minutes: 25, rule: rule, type: .pomodoro),
            windowEnd: date(2026, 7, 6, 12)
        )
        let work = occurrences.filter { !$0.id.contains("_break") && !$0.id.contains("_longbreak") }
        XCTAssertEqual(work.map(\.id), ["pomo", "pomo_occ1", "pomo_occ2"])
        XCTAssertEqual(work.compactMap(\.pomodoroRoundNumber), [1, 2, 3])
        XCTAssertEqual(Set(occurrences.compactMap(\.pomodoroSessionBaseId)), ["pomo"])
    }

    func testLegacyTimestampRoundIdGroupsButHasNoRound() {
        // Ids expanded by pre-fix builds can still be on screen: they
        // must group with their session, and must NOT claim «round 1».
        let legacy = CalendarEvent(
            id: "pomo_r1752000000",
            title: "Legacy",
            startDate: date(2026, 7, 6, 9),
            endDate: date(2026, 7, 6, 9, 25),
            eventType: .pomodoro
        )
        XCTAssertEqual(legacy.pomodoroSessionBaseId, "pomo")
        XCTAssertNil(legacy.pomodoroRoundNumber)
    }

    // MARK: EXDATE

    func testExcludedDateMatchesSameDayNotExactTimestamp() {
        // A date-only EXDATE resolves to local midnight; the 14:00
        // occurrence on that day must still be excluded.
        let rule = RecurrenceRule(frequency: .daily, end: .afterCount(3))
        let start = date(2026, 7, 20, 14)
        let midnightOfSecondDay = cal.startOfDay(for: date(2026, 7, 21, 14))
        let occurrences = RecurrenceExpander.expand(
            event(start: start, minutes: 30, rule: rule),
            windowEnd: date(2026, 7, 25),
            excludedDates: [midnightOfSecondDay]
        )
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertFalse(occurrences.contains { cal.isDate($0.startDate, inSameDayAs: date(2026, 7, 21)) })
    }

    // MARK: RRULE import

    func testMonthlyBydayWithoutOrdinalMapsToWeekly() {
        // RFC 5545: FREQ=MONTHLY;BYDAY=FR = every Friday. With
        // interval 1 that is exactly the weekly rule on Fridays.
        let rule = RecurrenceRule.fromRRULE("FREQ=MONTHLY;BYDAY=FR")
        XCTAssertEqual(rule?.frequency, .weekly)
        XCTAssertEqual(rule?.weekdays, [.friday])
        XCTAssertNil(rule?.monthlyMode)
    }

    func testMonthlyBydayWithOrdinalStaysMonthly() {
        let rule = RecurrenceRule.fromRRULE("FREQ=MONTHLY;BYDAY=2TU")
        XCTAssertEqual(rule?.frequency, .monthly)
        XCTAssertEqual(rule?.monthlyMode, .weekdayPosition(ordinal: 2, weekday: .tuesday))
    }
}
