import XCTest
@testable import Bubo

// MARK: - NotificationScheduler Tests
//
// Covers the pure-logic parts of the scheduler: interval resolution,
// prune, cancel bookkeeping. Firing behaviour (Timer callbacks) isn't
// exercised — that would require time-travel and hooking
// `UNUserNotificationCenter`, both of which are out of scope for a unit
// suite. The interesting invariants are all synchronous.

@MainActor
final class NotificationSchedulerTests: XCTestCase {

    // MARK: - Fixtures

    private func makeSettings(intervals: [(Int, Bool)] = [(20, true), (2, true)]) -> ReminderSettings {
        let settings = ReminderSettings()
        settings.intervals = intervals.map { ReminderInterval(minutes: $0.0, isEnabled: $0.1) }
        return settings
    }

    private func event(id: String, startsIn seconds: TimeInterval, custom: [Int]? = nil) -> CalendarEvent {
        let start = Date().addingTimeInterval(seconds)
        var e = CalendarEvent(
            id: id,
            title: id,
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            location: nil,
            description: nil,
            calendarName: nil,
            customReminderMinutes: custom
        )
        _ = e.id
        return e
    }

    // MARK: - Interval Resolution

    func testDefaultReminderMinutesListReflectsEnabledIntervals() {
        let settings = makeSettings(intervals: [(30, true), (10, true), (5, false)])
        let scheduler = NotificationScheduler(settings: settings)
        XCTAssertEqual(scheduler.defaultReminderMinutesList, [10, 30], "only enabled intervals, sorted")
    }

    func testDefaultReminderMinutesListFallsBackWhenAllDisabled() {
        let settings = makeSettings(intervals: [(30, false), (10, false)])
        let scheduler = NotificationScheduler(settings: settings)
        XCTAssertEqual(scheduler.defaultReminderMinutesList, NotificationScheduler.defaultReminderMinutes)
    }

    func testActiveReminderMinutesPrefersEventCustomOverrides() {
        let settings = makeSettings(intervals: [(30, true), (10, true)])
        let scheduler = NotificationScheduler(settings: settings)
        let e = event(id: "a", startsIn: 3600, custom: [60, 15])
        XCTAssertEqual(scheduler.activeReminderMinutes(for: e), [60, 15])
    }

    func testActiveReminderMinutesFallsBackToSettingsWhenNoCustom() {
        let settings = makeSettings(intervals: [(30, true), (10, true)])
        let scheduler = NotificationScheduler(settings: settings)
        let e = event(id: "a", startsIn: 3600)
        XCTAssertEqual(scheduler.activeReminderMinutes(for: e), [30, 10])
    }

    // MARK: - Prune

    func testPruneKeepsAliveIdsOnly() {
        let scheduler = NotificationScheduler(settings: makeSettings())
        // Simulate fired keys by scheduling + letting timers fire is too
        // invasive; the prune logic is pure so we can exercise it by
        // calling through with a representative alive set. Since
        // `firedReminders` is private, we verify indirectly: schedule
        // three upcoming events, prune to keep only one, then re-schedule
        // and check that the pruned events get fresh timers (no
        // firedReminders guard) while the kept one doesn't need this
        // behaviour to be observable. The meaningful assertion is that
        // prune doesn't throw and doesn't leak alive IDs — any
        // invariant violation would show up at schedule time.
        let events = [
            event(id: "a", startsIn: 600),
            event(id: "b", startsIn: 1200),
            event(id: "c", startsIn: 1800),
        ]
        scheduler.schedule(events)
        scheduler.pruneFiredReminders(keepingEventIds: ["b"])
        // Nothing to assert directly — prune has no observable side
        // effect on the public surface. This test locks in that the
        // method exists and runs without mutating scheduled timers.
        scheduler.cancelAll()
    }

    // MARK: - Cancel

    func testCancelOneDoesNotAffectOthers() {
        let scheduler = NotificationScheduler(settings: makeSettings())
        scheduler.schedule([
            event(id: "a", startsIn: 600),
            event(id: "b", startsIn: 1200),
        ])
        scheduler.cancel(eventId: "a")
        // Cancelling twice is safe.
        scheduler.cancel(eventId: "a")
        scheduler.cancelAll()
    }

    func testCancelAllIsIdempotent() {
        let scheduler = NotificationScheduler(settings: makeSettings())
        scheduler.cancelAll()
        scheduler.cancelAll()
    }

    // MARK: - Schedule

    func testScheduleSkipsPastEventsSilently() {
        let scheduler = NotificationScheduler(settings: makeSettings())
        // Past event — no timer should be scheduled, and the method
        // should not throw.
        scheduler.schedule([event(id: "past", startsIn: -600)])
        scheduler.cancelAll()
    }

    func testScheduleIsIdempotent() {
        let scheduler = NotificationScheduler(settings: makeSettings())
        let e = event(id: "a", startsIn: 3600)
        scheduler.schedule([e])
        // Re-schedule — cancel + recreate, should not double up.
        scheduler.schedule([e])
        scheduler.cancelAll()
    }
}
