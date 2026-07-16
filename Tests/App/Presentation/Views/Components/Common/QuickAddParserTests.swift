import XCTest
@testable import Bubo
@testable import BuboDomain

// MARK: - QuickAddParser tests
//
// Pins the one rule the unified «Add» front door lives by: an explicit
// clock time makes the text an event, everything else is a task. Every
// case here is a promise the live interpretation preview shows the
// user — a change that breaks one of these silently reroutes their
// input to the wrong bucket.

final class QuickAddParserTests: XCTestCase {

    // Fixed clock: Monday 2026-07-06, 09:00 UTC.
    private static func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int = 0
    ) -> Date {
        calendar().date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private let cal = Self.calendar()
    private let monday9am = Self.date(2026, 7, 6, 9)

    // MARK: Tasks

    func testPlainTextIsTask() {
        let parsed = QuickAddParser.parse("Buy milk", now: monday9am, calendar: cal)
        XCTAssertEqual(parsed, .task(title: "Buy milk", durationMinutes: nil))
    }

    func testTrailingDurationStaysTask() {
        let parsed = QuickAddParser.parse("Write report 30m", now: monday9am, calendar: cal)
        XCTAssertEqual(parsed, .task(title: "Write report", durationMinutes: 30))
    }

    func testBareNumberIsNotATime() {
        // No colon, no am/pm → a count, not a clock time.
        let parsed = QuickAddParser.parse("Buy 2 lamps", now: monday9am, calendar: cal)
        XCTAssertEqual(parsed, .task(title: "Buy 2 lamps", durationMinutes: nil))
    }

    // MARK: Events — 24-hour form

    func testClockTimeMakesEventToday() {
        let parsed = QuickAddParser.parse("Lunch with Anna 13:00", now: monday9am, calendar: cal)
        // «lunch» has no verb-table entry → the 30-minute form default.
        XCTAssertEqual(parsed, .event(
            title: "Lunch with Anna",
            start: Self.date(2026, 7, 6, 13),
            durationMinutes: 30
        ))
    }

    func testPastTimeRollsToTomorrow() {
        let at3pm = Self.date(2026, 7, 6, 15)
        let parsed = QuickAddParser.parse("Lunch 13:00", now: at3pm, calendar: cal)
        XCTAssertEqual(parsed, .event(
            title: "Lunch",
            start: Self.date(2026, 7, 7, 13),
            durationMinutes: 30
        ))
    }

    func testExplicitTodayNeverRolls() {
        // An explicit day word wins even when the moment has passed —
        // the user said today, the machine doesn't overrule them.
        let parsed = QuickAddParser.parse("Review today 8:00", now: monday9am, calendar: cal)
        guard case let .event(title, start, _) = parsed else {
            return XCTFail("expected .event, got \(parsed)")
        }
        XCTAssertEqual(title, "Review")
        XCTAssertEqual(start, Self.date(2026, 7, 6, 8))
    }

    func testTomorrowWordWithTimeAndDuration() {
        let parsed = QuickAddParser.parse("Standup tomorrow 9:30 15m", now: monday9am, calendar: cal)
        XCTAssertEqual(parsed, .event(
            title: "Standup",
            start: Self.date(2026, 7, 7, 9, 30),
            durationMinutes: 15
        ))
    }

    // MARK: Events — 12-hour form

    func testMeridiemHourOnlyForm() {
        let parsed = QuickAddParser.parse("Gym at 7pm 1h", now: monday9am, calendar: cal)
        XCTAssertEqual(parsed, .event(
            title: "Gym",
            start: Self.date(2026, 7, 6, 19),
            durationMinutes: 60
        ))
    }

    func testMeridiemOnColonForm() {
        let parsed = QuickAddParser.parse("Dinner 6:30pm", now: monday9am, calendar: cal)
        guard case let .event(_, start, _) = parsed else {
            return XCTFail("expected .event, got \(parsed)")
        }
        XCTAssertEqual(start, Self.date(2026, 7, 6, 18, 30))
    }

    func testNoonAndMidnightNormalization() {
        // 12pm = 12:00 — the case people reliably get wrong.
        let noon = QuickAddParser.parse("Call mom 12pm", now: monday9am, calendar: cal)
        guard case let .event(_, noonStart, _) = noon else {
            return XCTFail("expected .event, got \(noon)")
        }
        XCTAssertEqual(noonStart, Self.date(2026, 7, 6, 12))

        // 12am = 00:00 → already past at 09:00 → rolls to tomorrow.
        let midnight = QuickAddParser.parse("Backup 12am", now: monday9am, calendar: cal)
        guard case let .event(_, midnightStart, _) = midnight else {
            return XCTFail("expected .event, got \(midnight)")
        }
        XCTAssertEqual(midnightStart, Self.date(2026, 7, 7, 0))
    }

    // MARK: Events — duration fallbacks

    func testVerbGuessFillsEventDuration() {
        // «meeting» sits in the verb table at 60 min.
        let parsed = QuickAddParser.parse("Meeting with Bob 14:00", now: monday9am, calendar: cal)
        guard case let .event(_, _, minutes) = parsed else {
            return XCTFail("expected .event, got \(parsed)")
        }
        XCTAssertEqual(minutes, 60)
    }

    // MARK: Title hygiene

    func testDayWordAfterTimeCleansTitleCorrectly() {
        // Regression pin: the time token sits BEFORE the day word, so
        // the two cut ranges must be removed back-to-front — cutting the
        // time first would shift «tomorrow»'s range onto the wrong
        // characters and corrupt the title.
        let parsed = QuickAddParser.parse("Standup 9:30 tomorrow", now: monday9am, calendar: cal)
        XCTAssertEqual(parsed, .event(
            title: "Standup",
            start: Self.date(2026, 7, 7, 9, 30),
            durationMinutes: 15
        ))
    }

    func testTimeOnlyFallsBackToUntitled() {
        let parsed = QuickAddParser.parse("13:00", now: monday9am, calendar: cal)
        guard case let .event(title, _, _) = parsed else {
            return XCTFail("expected .event, got \(parsed)")
        }
        XCTAssertEqual(title, "Untitled")
    }

    // MARK: Forced modes — the QuickAddView segmented control
    //
    // `.task` / `.event` pin the interpretation regardless of the text;
    // `.auto` (the default parameter every test above exercises) keeps
    // the clock-time rule.

    func testForcedTaskIgnoresClockTime() {
        // The user chose the task vocabulary — the time text stays in
        // the title, nothing is dropped or rerouted.
        let parsed = QuickAddParser.parse(
            "Lunch with Anna 13:00", mode: .task, now: monday9am, calendar: cal
        )
        XCTAssertEqual(parsed, .task(title: "Lunch with Anna 13:00", durationMinutes: nil))
    }

    func testForcedTaskStillParsesTrailingDuration() {
        let parsed = QuickAddParser.parse(
            "Write report 30m", mode: .task, now: monday9am, calendar: cal
        )
        XCTAssertEqual(parsed, .task(title: "Write report", durationMinutes: 30))
    }

    func testForcedEventWithExplicitTimeMatchesAuto() {
        let forced = QuickAddParser.parse(
            "Lunch with Anna 13:00", mode: .event, now: monday9am, calendar: cal
        )
        let auto = QuickAddParser.parse(
            "Lunch with Anna 13:00", now: monday9am, calendar: cal
        )
        XCTAssertEqual(forced, auto)
    }

    func testForcedEventWithoutTimeDefaultsToNextQuarterHour() {
        // 09:00 sits exactly on a boundary → strictly-after means 09:15.
        let parsed = QuickAddParser.parse(
            "Coffee", mode: .event, now: monday9am, calendar: cal
        )
        XCTAssertEqual(parsed, .event(
            title: "Coffee",
            start: Self.date(2026, 7, 6, 9, 15),
            durationMinutes: 30
        ))
    }

    func testForcedEventDefaultStartRoundsUpMidInterval() {
        let at907 = Self.date(2026, 7, 6, 9, 7)
        let parsed = QuickAddParser.parse(
            "Coffee", mode: .event, now: at907, calendar: cal
        )
        guard case let .event(_, start, _) = parsed else {
            return XCTFail("expected .event, got \(parsed)")
        }
        XCTAssertEqual(start, Self.date(2026, 7, 6, 9, 15))
    }

    func testForcedEventWithoutTimeHonoursTomorrowWord() {
        let parsed = QuickAddParser.parse(
            "Dentist tomorrow", mode: .event, now: monday9am, calendar: cal
        )
        guard case let .event(title, start, _) = parsed else {
            return XCTFail("expected .event, got \(parsed)")
        }
        XCTAssertEqual(title, "Dentist")
        XCTAssertEqual(start, Self.date(2026, 7, 7, 9, 15))
    }

    func testForcedEventKeepsExplicitDuration() {
        let parsed = QuickAddParser.parse(
            "Focus block 1h", mode: .event, now: monday9am, calendar: cal
        )
        XCTAssertEqual(parsed, .event(
            title: "Focus block",
            start: Self.date(2026, 7, 6, 9, 15),
            durationMinutes: 60
        ))
    }

    // MARK: hasExplicitTime — drives the §6 tilde on defaulted starts

    func testHasExplicitTimeDetectsClockForms() {
        XCTAssertTrue(QuickAddParser.hasExplicitTime("Lunch 13:00"))
        XCTAssertTrue(QuickAddParser.hasExplicitTime("Gym at 7pm"))
        XCTAssertFalse(QuickAddParser.hasExplicitTime("Coffee"))
        // A trailing duration is not a clock time.
        XCTAssertFalse(QuickAddParser.hasExplicitTime("Write report 30m"))
    }
}
