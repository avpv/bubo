import XCTest
import SwiftData
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - BacklogLogic tests
//
// Pure-function layer extracted from `BacklogView` so smart-sort, urgent
// filter, sprint cap, completed-today and capacity math can be exercised
// without spinning up a SwiftUI host.

final class BacklogLogicTests: XCTestCase {

    private static func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private static func now() -> Date {
        Self.calendar().date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 10
        ))!
    }

    private func task(
        _ id: String,
        status: BacklogStatus = .pending,
        deadline: Date? = nil,
        priority: TaskPriority = .medium,
        completedAt: Date? = nil,
        duration: Int = 60
    ) -> BacklogTask {
        var t = BacklogTask(
            id: id,
            title: id,
            durationMinutes: duration,
            priority: priority,
            deadline: deadline
        )
        t.status = status
        t.completedAt = completedAt
        return t
    }

    // MARK: activeTasks

    func testActiveTasksExcludesDoneAndFrozen() {
        let tasks = [
            task("a"),
            task("b", status: .done),
            task("c", status: .frozen),
            task("d", status: .scheduled),
        ]
        XCTAssertEqual(BacklogLogic.activeTasks(tasks).map(\.id), ["a", "d"])
    }

    func testActiveTasksPreservesOrder() {
        let tasks = [task("c"), task("a"), task("b")]
        XCTAssertEqual(BacklogLogic.activeTasks(tasks).map(\.id), ["c", "a", "b"])
    }

    // MARK: urgent

    func testUrgentTasksIncludesWithinWindow() {
        let cal = Self.calendar()
        let n = Self.now()
        let tomorrow = cal.date(byAdding: .day, value: 1, to: n)!
        let nextWeek = cal.date(byAdding: .day, value: 7, to: n)!
        let tasks = [
            task("urgent", deadline: tomorrow),
            task("far", deadline: nextWeek),
            task("none"),
        ]
        let urgent = BacklogLogic.urgentTasks(tasks, withinDays: 2, now: n, calendar: cal)
        XCTAssertEqual(urgent.map(\.id), ["urgent"])
    }

    func testUrgentExcludesDoneAndFrozen() {
        let cal = Self.calendar()
        let n = Self.now()
        let tomorrow = cal.date(byAdding: .day, value: 1, to: n)!
        let tasks = [
            task("a", status: .done, deadline: tomorrow),
            task("b", status: .frozen, deadline: tomorrow),
            task("c", deadline: tomorrow),
        ]
        XCTAssertEqual(
            BacklogLogic.urgentTasks(tasks, now: n, calendar: cal).map(\.id),
            ["c"]
        )
    }

    func testIsUrgentMatchesUrgentTasks() {
        let cal = Self.calendar()
        let n = Self.now()
        let tomorrow = cal.date(byAdding: .day, value: 1, to: n)!
        let nextWeek = cal.date(byAdding: .day, value: 7, to: n)!
        XCTAssertTrue(BacklogLogic.isUrgent(task("a", deadline: tomorrow), now: n, calendar: cal))
        XCTAssertFalse(BacklogLogic.isUrgent(task("b", deadline: nextWeek), now: n, calendar: cal))
        XCTAssertFalse(BacklogLogic.isUrgent(task("c"), now: n, calendar: cal))
    }

    // MARK: smart filters

    func testMatchesSmartFilterToday() {
        let cal = Self.calendar()
        let n = Self.now()
        let today = cal.date(bySettingHour: 18, minute: 0, second: 0, of: n)!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: n)!
        XCTAssertTrue(BacklogLogic.matchesSmartFilter(
            task("a", deadline: today),
            filter: .today, now: n, calendar: cal
        ))
        XCTAssertFalse(BacklogLogic.matchesSmartFilter(
            task("b", deadline: tomorrow),
            filter: .today, now: n, calendar: cal
        ))
        XCTAssertFalse(BacklogLogic.matchesSmartFilter(
            task("c"),
            filter: .today, now: n, calendar: cal
        ))
    }

    func testMatchesSmartFilterOverdue() {
        let cal = Self.calendar()
        let n = Self.now()
        let yesterday = cal.date(byAdding: .day, value: -1, to: n)!
        let todayLate = cal.date(bySettingHour: 23, minute: 0, second: 0, of: n)!
        XCTAssertTrue(BacklogLogic.matchesSmartFilter(
            task("y", deadline: yesterday),
            filter: .overdue, now: n, calendar: cal
        ))
        // "Today, but later in the day" is NOT overdue — overdue means
        // strictly before today's start so the chip never claims things
        // the user could still finish today.
        XCTAssertFalse(BacklogLogic.matchesSmartFilter(
            task("t", deadline: todayLate),
            filter: .overdue, now: n, calendar: cal
        ))
    }

    func testMatchesSmartFilterScheduled() {
        let cal = Self.calendar()
        let n = Self.now()
        XCTAssertTrue(BacklogLogic.matchesSmartFilter(
            task("a", status: .scheduled),
            filter: .scheduled, now: n, calendar: cal
        ))
        XCTAssertFalse(BacklogLogic.matchesSmartFilter(
            task("b", status: .pending),
            filter: .scheduled, now: n, calendar: cal
        ))
    }

    func testMatchesSmartFilterFlaggedMapsToHighPriority() {
        let cal = Self.calendar()
        let n = Self.now()
        XCTAssertTrue(BacklogLogic.matchesSmartFilter(
            task("a", priority: .high),
            filter: .flagged, now: n, calendar: cal
        ))
        XCTAssertFalse(BacklogLogic.matchesSmartFilter(
            task("b", priority: .medium),
            filter: .flagged, now: n, calendar: cal
        ))
        XCTAssertFalse(BacklogLogic.matchesSmartFilter(
            task("c", priority: .low),
            filter: .flagged, now: n, calendar: cal
        ))
    }

    func testMatchesSmartFilterExcludesDoneAndFrozen() {
        let cal = Self.calendar()
        let n = Self.now()
        let tomorrow = cal.date(byAdding: .day, value: 1, to: n)!
        XCTAssertFalse(BacklogLogic.matchesSmartFilter(
            task("done", status: .done, deadline: n),
            filter: .today, now: n, calendar: cal
        ))
        XCTAssertFalse(BacklogLogic.matchesSmartFilter(
            task("frozen", status: .frozen, deadline: tomorrow, priority: .high),
            filter: .flagged, now: n, calendar: cal
        ))
    }

    func testSmartFilterCountsTallyEachBucket() {
        let cal = Self.calendar()
        let n = Self.now()
        let today = cal.date(bySettingHour: 18, minute: 0, second: 0, of: n)!
        let yesterday = cal.date(byAdding: .day, value: -1, to: n)!
        let tasks = [
            task("od", deadline: yesterday),
            task("td", deadline: today),
            task("sc", status: .scheduled),
            task("fl", priority: .high),
            task("fl-od", deadline: yesterday, priority: .high),
            task("done-skip", status: .done, deadline: yesterday),
        ]
        let counts = BacklogLogic.smartFilterCounts(tasks, now: n, calendar: cal)
        XCTAssertEqual(counts[.overdue], 2)   // od + fl-od
        XCTAssertEqual(counts[.today], 1)     // td
        XCTAssertEqual(counts[.scheduled], 1) // sc
        XCTAssertEqual(counts[.flagged], 2)   // fl + fl-od
    }

    // MARK: smart sort

    func testSmartSortDeadlineDominatesPriority() {
        let cal = Self.calendar()
        let n = Self.now()
        let today = n
        let lowToday = task("low-today", deadline: today, priority: .low)
        let highFar = task(
            "high-far",
            deadline: cal.date(byAdding: .day, value: 10, to: n),
            priority: .high
        )
        let sorted = BacklogLogic.smartSorted([highFar, lowToday], now: n, calendar: cal)
        XCTAssertEqual(sorted.first?.id, "low-today",
                       "Today-deadline must win against high-priority-but-far task")
    }

    func testSmartSortStableOnTies() {
        let cal = Self.calendar()
        let n = Self.now()
        // Two tasks with identical deadline + priority → order equals input order.
        let a = task("a", deadline: n, priority: .medium)
        let b = task("b", deadline: n, priority: .medium)
        XCTAssertEqual(
            BacklogLogic.smartSorted([a, b], now: n, calendar: cal).map(\.id),
            ["a", "b"]
        )
        XCTAssertEqual(
            BacklogLogic.smartSorted([b, a], now: n, calendar: cal).map(\.id),
            ["b", "a"]
        )
    }

    func testSmartSortHighPriorityWithNoDeadlineBeatsLowPriorityFarOut() {
        let cal = Self.calendar()
        let n = Self.now()
        let highNoDeadline = task("h", priority: .high)
        let lowFar = task(
            "l",
            deadline: cal.date(byAdding: .day, value: 14, to: n),
            priority: .low
        )
        let sorted = BacklogLogic.smartSorted([lowFar, highNoDeadline], now: n, calendar: cal)
        XCTAssertEqual(sorted.first?.id, "h")
    }

    // MARK: completed today

    func testCompletedTodayIncludesOnlyDoneAfterStartOfDay() {
        let cal = Self.calendar()
        let n = Self.now()
        let earlyToday = cal.date(bySettingHour: 2, minute: 0, second: 0, of: n)!
        let yesterday = cal.date(byAdding: .day, value: -1, to: n)!
        let tasks = [
            task("pending"),
            task("today", status: .done, completedAt: earlyToday),
            task("old", status: .done, completedAt: yesterday),
        ]
        let completed = BacklogLogic.completedToday(tasks, now: n, calendar: cal)
        XCTAssertEqual(completed.map(\.id), ["today"])
    }

    func testCompletedTodayOrdersMostRecentFirst() {
        let cal = Self.calendar()
        let n = Self.now()
        let early = cal.date(bySettingHour: 2, minute: 0, second: 0, of: n)!
        let late = cal.date(bySettingHour: 9, minute: 30, second: 0, of: n)!
        let tasks = [
            task("early", status: .done, completedAt: early),
            task("late", status: .done, completedAt: late),
        ]
        XCTAssertEqual(
            BacklogLogic.completedToday(tasks, now: n, calendar: cal).map(\.id),
            ["late", "early"]
        )
    }

    // MARK: capacity

    func testCapacityFractionEmptyBacklogIsZero() {
        XCTAssertEqual(
            BacklogLogic.capacityFraction(pendingMinutes: 0, remainingWorkdayMinutes: 120),
            0
        )
    }

    func testCapacityFractionWorkdayOverReturnsQueuedSentinel() {
        // 1.1 = the ring's warning band, not the destructive one: work
        // parked after hours is a re-plan opportunity, not a fault
        // (PRINCIPLES §7 — saturated red is reserved for broken/overdue).
        XCTAssertEqual(
            BacklogLogic.capacityFraction(pendingMinutes: 60, remainingWorkdayMinutes: 0),
            1.1
        )
    }

    func testCapacityFractionEmptyBacklogAfterHoursIsZero() {
        XCTAssertEqual(
            BacklogLogic.capacityFraction(pendingMinutes: 0, remainingWorkdayMinutes: 0),
            0
        )
    }

    func testCapacityFractionComputesRatio() {
        XCTAssertEqual(
            BacklogLogic.capacityFraction(pendingMinutes: 180, remainingWorkdayMinutes: 60),
            3.0
        )
    }

    // MARK: remaining workday

    func testRemainingWorkdayClampedToZeroPastEndOfDay() {
        let cal = Self.calendar()
        let late = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 22
        ))!
        XCTAssertEqual(
            BacklogLogic.remainingWorkdayMinutes(workingHours: 9...18, now: late, calendar: cal),
            0
        )
    }

    func testRemainingWorkdayComputesMinutes() {
        let cal = Self.calendar()
        let noon = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 12
        ))!
        XCTAssertEqual(
            BacklogLogic.remainingWorkdayMinutes(workingHours: 9...18, now: noon, calendar: cal),
            6 * 60
        )
    }

    func testRemainingWorkdayClampsToWindowOpening() {
        // 07:00 with a 9–18 window: usable capacity is the full 9h
        // window, NOT 11h — the hours before the workday opens are not
        // capacity.
        let cal = Self.calendar()
        let early = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 7
        ))!
        XCTAssertEqual(
            BacklogLogic.remainingWorkdayMinutes(workingHours: 9...18, now: early, calendar: cal),
            9 * 60
        )
    }

    // MARK: capacity forecast

    func testCapacityForecastFitsReturnsETAAndSpare() {
        let cal = Self.calendar()
        let noon = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 12
        ))!
        // 12:00 with workday 9–18 → 360 min remaining; 90 min queued fits.
        let forecast = BacklogLogic.capacityForecast(
            pendingMinutes: 90,
            workingHours: 9...18,
            now: noon,
            calendar: cal
        )
        guard case let .fits(eta, spareMinutes) = forecast else {
            XCTFail("expected .fits, got \(forecast)")
            return
        }
        XCTAssertEqual(eta, noon.addingTimeInterval(90 * 60))
        XCTAssertEqual(spareMinutes, 360 - 90)
    }

    func testCapacityForecastFitsExactlyAtEndOfDay() {
        let cal = Self.calendar()
        let noon = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 12
        ))!
        // Pending exactly equals remaining → still .fits, zero spare.
        let forecast = BacklogLogic.capacityForecast(
            pendingMinutes: 360,
            workingHours: 9...18,
            now: noon,
            calendar: cal
        )
        guard case let .fits(_, spareMinutes) = forecast else {
            XCTFail("expected .fits, got \(forecast)")
            return
        }
        XCTAssertEqual(spareMinutes, 0)
    }

    func testCapacityForecastBeforeWorkdayAnchorsETAAtOpening() {
        // 07:00, 9–18 window, 120 min queued: the ETA counts from the
        // 09:00 opening (→ 11:00), never from a pre-workday clock (the
        // old behaviour promised 09:00-completion for work that can't
        // start before 09:00).
        let cal = Self.calendar()
        let early = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 7
        ))!
        let opening = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 9
        ))!
        let forecast = BacklogLogic.capacityForecast(
            pendingMinutes: 120,
            workingHours: 9...18,
            now: early,
            calendar: cal
        )
        guard case let .fits(eta, spareMinutes) = forecast else {
            XCTFail("expected .fits, got \(forecast)")
            return
        }
        XCTAssertEqual(eta, opening.addingTimeInterval(120 * 60))
        XCTAssertEqual(spareMinutes, 9 * 60 - 120)
    }

    func testCapacityForecastOverReturnsOverflow() {
        let cal = Self.calendar()
        let noon = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 12
        ))!
        // 360 remaining, 500 queued → .over by 140.
        let forecast = BacklogLogic.capacityForecast(
            pendingMinutes: 500,
            workingHours: 9...18,
            now: noon,
            calendar: cal
        )
        XCTAssertEqual(forecast, .over(byMinutes: 140))
    }

    func testCapacityForecastAfterHoursWhenWorkdayClosed() {
        let cal = Self.calendar()
        let evening = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 22
        ))!
        let forecast = BacklogLogic.capacityForecast(
            pendingMinutes: 120,
            workingHours: 9...18,
            now: evening,
            calendar: cal
        )
        XCTAssertEqual(forecast, .afterHours(queuedMinutes: 120))
    }

    func testCapacityForecastAfterHoursOnOffDay() {
        let cal = Self.calendar()
        // 2026-04-11 is a Saturday; with workingDays={2..6} (Mon–Fri) the
        // workday window is empty, regardless of clock time.
        let saturdayNoon = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 12
        ))!
        let forecast = BacklogLogic.capacityForecast(
            pendingMinutes: 60,
            workingHours: 9...18,
            workingDays: [2, 3, 4, 5, 6],
            now: saturdayNoon,
            calendar: cal
        )
        XCTAssertEqual(forecast, .afterHours(queuedMinutes: 60))
    }

    func testCapacityForecastEmptyBacklogAfterHoursIsNeverHard() {
        // Closed window + nothing queued must not read as an alarm —
        // every consumer treats `.afterHours` as the hard state that
        // surfaces the «Schedule overflow» verb, which is meaningless
        // over zero tasks.
        let cal = Self.calendar()
        let evening = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 22
        ))!
        let forecast = BacklogLogic.capacityForecast(
            pendingMinutes: 0,
            workingHours: 9...18,
            now: evening,
            calendar: cal
        )
        guard case .fits = forecast else {
            XCTFail("expected .fits for an empty backlog, got \(forecast)")
            return
        }
    }

    func testCapacityForecastEmptyBacklogStillFits() {
        let cal = Self.calendar()
        let noon = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 12
        ))!
        let forecast = BacklogLogic.capacityForecast(
            pendingMinutes: 0,
            workingHours: 9...18,
            now: noon,
            calendar: cal
        )
        guard case let .fits(eta, spareMinutes) = forecast else {
            XCTFail("expected .fits, got \(forecast)")
            return
        }
        XCTAssertEqual(eta, noon)
        XCTAssertEqual(spareMinutes, 360)
    }

    // MARK: capacity partition

    func testCapacityPartitionAllFit() {
        let tasks = [task("a", duration: 30), task("b", duration: 60), task("c", duration: 30)]
        let result = BacklogLogic.capacityPartition(tasks, remainingWorkdayMinutes: 240)
        XCTAssertEqual(result.fitting.map(\.id), ["a", "b", "c"])
        XCTAssertTrue(result.overflowing.isEmpty)
    }

    func testCapacityPartitionAllOverflow() {
        let tasks = [task("a", duration: 60), task("b", duration: 60)]
        let result = BacklogLogic.capacityPartition(tasks, remainingWorkdayMinutes: 0)
        XCTAssertTrue(result.fitting.isEmpty)
        XCTAssertEqual(result.overflowing.map(\.id), ["a", "b"])
    }

    func testCapacityPartitionPreservesOrder() {
        // Greedy fill walks left-to-right, so a small task that comes after
        // a too-big one still spills — partition is order-respecting, not
        // best-fit packing. Lets the caller pick the order (smart-sort vs
        // storage) and predict the result.
        let tasks = [
            task("big",   duration: 90),
            task("small", duration: 30),
            task("tiny",  duration: 15),
        ]
        let result = BacklogLogic.capacityPartition(tasks, remainingWorkdayMinutes: 60)
        XCTAssertTrue(result.fitting.isEmpty)
        XCTAssertEqual(result.overflowing.map(\.id), ["big", "small", "tiny"])
    }

    func testCapacityPartitionGreedyCutoff() {
        // 60 min budget, 30+30+30. First two fit exactly (60 min consumed),
        // third spills.
        let tasks = [task("a", duration: 30), task("b", duration: 30), task("c", duration: 30)]
        let result = BacklogLogic.capacityPartition(tasks, remainingWorkdayMinutes: 60)
        XCTAssertEqual(result.fitting.map(\.id), ["a", "b"])
        XCTAssertEqual(result.overflowing.map(\.id), ["c"])
    }

    func testCapacityPartitionEmpty() {
        let result = BacklogLogic.capacityPartition([], remainingWorkdayMinutes: 240)
        XCTAssertTrue(result.fitting.isEmpty)
        XCTAssertTrue(result.overflowing.isEmpty)
    }

    func testCapacityPartitionNegativeBudgetClamps() {
        // Budget passed in negative (caller used a stale pre-clamped value)
        // — partition should treat it as zero, not propagate the error.
        let tasks = [task("a", duration: 30)]
        let result = BacklogLogic.capacityPartition(tasks, remainingWorkdayMinutes: -120)
        XCTAssertTrue(result.fitting.isEmpty)
        XCTAssertEqual(result.overflowing.map(\.id), ["a"])
    }

    // MARK: capacity section plan

    func testCapacitySectionPlanComputesOverflowMinutes() {
        let tasks = [
            task("a", duration: 60),
            task("b", duration: 90),
            task("c", duration: 45),
        ]
        let plan = BacklogLogic.CapacitySectionPlan(
            orderedTasks: tasks,
            remainingWorkdayMinutes: 60
        )
        XCTAssertEqual(plan.fitting.map(\.id), ["a"])
        XCTAssertEqual(plan.overflowing.map(\.id), ["b", "c"])
        XCTAssertEqual(plan.overflowMinutes, 90 + 45)
    }

    func testCapacitySectionPlanFlagsUrgentInOverflow() {
        let cal = Self.calendar()
        let dueToday = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 17
        ))!
        let tasks = [
            task("a", duration: 60),
            task("urgent", deadline: dueToday, duration: 90),
        ]
        let plan = BacklogLogic.CapacitySectionPlan(
            orderedTasks: tasks,
            remainingWorkdayMinutes: 60
        )
        XCTAssertTrue(plan.overflowHasUrgent)
        XCTAssertTrue(plan.hasOverflow)
    }

    func testCapacitySectionPlanReportsNoOverflowWhenAllFit() {
        let tasks = [task("a", duration: 30), task("b", duration: 30)]
        let plan = BacklogLogic.CapacitySectionPlan(
            orderedTasks: tasks,
            remainingWorkdayMinutes: 240
        )
        XCTAssertFalse(plan.hasOverflow)
        XCTAssertEqual(plan.overflowMinutes, 0)
        XCTAssertFalse(plan.overflowHasUrgent)
    }

    // MARK: capacity label suffix

    func testCapacityLabelSuffixIsEmptyWhenNoOverflow() {
        let forecast = BacklogLogic.CapacityForecast.fits(eta: Self.now(), spareMinutes: 60)
        XCTAssertEqual(
            BacklogCapacityLabel.suffix(forecast: forecast, overflowingCount: 0),
            ""
        )
    }

    func testCapacityLabelSuffixSingularForOneTask() {
        let forecast = BacklogLogic.CapacityForecast.over(byMinutes: 60)
        let suffix = BacklogCapacityLabel.suffix(forecast: forecast, overflowingCount: 1)
        // Birman: «1 task doesn't fit» — singular noun, no plural-S.
        XCTAssertTrue(suffix.contains("1\u{00A0}task"))
        XCTAssertTrue(suffix.contains("doesn't"))
    }

    func testCapacityLabelSuffixPluralForMany() {
        let forecast = BacklogLogic.CapacityForecast.over(byMinutes: 240)
        let suffix = BacklogCapacityLabel.suffix(forecast: forecast, overflowingCount: 11)
        // Plural form drops the noun, just «11 don't fit».
        XCTAssertTrue(suffix.contains("11"))
        XCTAssertTrue(suffix.contains("don't"))
        XCTAssertFalse(suffix.contains("task"))
    }

    func testCapacityLabelSuffixUsesNonBreakingSpaceBeforeMiddot() {
        let forecast = BacklogLogic.CapacityForecast.over(byMinutes: 60)
        let suffix = BacklogCapacityLabel.suffix(forecast: forecast, overflowingCount: 3)
        // The leading «\u{00A0}·\u{00A0}» glues the suffix to the
        // preceding verdict so a line break never lands between them.
        XCTAssertTrue(suffix.hasPrefix("\u{00A0}·\u{00A0}"))
    }

    // MARK: capacity label verdict

    func testCapacityLabelFitsReadsAsDoneByTime() {
        let cal = Self.calendar()
        let noon = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 12
        ))!
        let forecast = BacklogLogic.CapacityForecast.fits(eta: noon, spareMinutes: 0)
        let label = BacklogCapacityLabel.label(for: forecast)
        // The exact rendered time depends on the test environment locale,
        // but the «Done by» prefix is invariant.
        XCTAssertTrue(label.hasPrefix("Done by"))
    }

    func testCapacityLabelOverReadsAsXOverCapacity() {
        let forecast = BacklogLogic.CapacityForecast.over(byMinutes: 60)
        let label = BacklogCapacityLabel.label(for: forecast)
        XCTAssertTrue(label.contains("over capacity"))
        XCTAssertTrue(label.contains("1\u{00A0}h"))
    }

    func testCapacityLabelAfterHoursReadsAsQueued() {
        let forecast = BacklogLogic.CapacityForecast.afterHours(queuedMinutes: 90)
        let label = BacklogCapacityLabel.label(for: forecast)
        XCTAssertTrue(label.hasPrefix("After hours"))
        XCTAssertTrue(label.contains("queued"))
        XCTAssertTrue(label.contains("1\u{00A0}h\u{00A0}30\u{00A0}min"))
    }

    // MARK: capacity label accessibility

    func testCapacityLabelAccessibilityIncludesOverflowCount() {
        let forecast = BacklogLogic.CapacityForecast.over(byMinutes: 60)
        let voiceOver = BacklogCapacityLabel.accessibilityLabel(
            for: forecast,
            pendingMinutes: 240,
            overflowingCount: 3
        )
        XCTAssertTrue(voiceOver.contains("over capacity"))
        // VoiceOver phrasing names «N tasks don't fit today» so the
        // assistive-tech reader hears the count without parsing
        // arithmetic.
        XCTAssertTrue(voiceOver.contains("3\u{00A0}tasks don't fit today"))
    }

    func testCapacityLabelAccessibilityOmitsCountWhenZero() {
        let forecast = BacklogLogic.CapacityForecast.fits(eta: Self.now(), spareMinutes: 60)
        let voiceOver = BacklogCapacityLabel.accessibilityLabel(
            for: forecast,
            pendingMinutes: 60,
            overflowingCount: 0
        )
        XCTAssertFalse(voiceOver.contains("don't fit"))
    }
}

// MARK: - RecurrenceEngine tests

final class RecurrenceEngineTests: XCTestCase {

    private static func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private static func now() -> Date {
        Self.calendar().date(from: DateComponents(
            year: 2026, month: 4, day: 11, hour: 10
        ))!
    }

    // MARK: frequency mapping

    func testFrequencyRecognisesDaily() {
        XCTAssertEqual(RecurrenceEngine.frequency(for: "daily"), .daily)
        XCTAssertEqual(RecurrenceEngine.frequency(for: "daily standup"), .daily)
        XCTAssertEqual(RecurrenceEngine.frequency(for: "every day"), .daily)
        XCTAssertEqual(RecurrenceEngine.frequency(for: "standup"), .daily)
    }

    func testFrequencyRecognisesWeekly() {
        XCTAssertEqual(RecurrenceEngine.frequency(for: "weekly review"), .weekly)
        XCTAssertEqual(RecurrenceEngine.frequency(for: "weekly meeting"), .weekly)
    }

    func testFrequencyRecognisesMonthly() {
        XCTAssertEqual(RecurrenceEngine.frequency(for: "monthly report"), .monthly)
        XCTAssertEqual(RecurrenceEngine.frequency(for: "monthly summary"), .monthly)
    }

    func testFrequencyRecognisesBiweekly() {
        XCTAssertEqual(RecurrenceEngine.frequency(for: "biweekly 1:1"), .biweekly)
        XCTAssertEqual(RecurrenceEngine.frequency(for: "fortnight plan"), .biweekly)
    }

    func testFrequencyRecognisesQuarterly() {
        XCTAssertEqual(RecurrenceEngine.frequency(for: "quarterly review"), .quarterly)
        XCTAssertEqual(RecurrenceEngine.frequency(for: "quarter plan"), .quarterly)
    }

    func testFrequencyRecognisesYearly() {
        XCTAssertEqual(RecurrenceEngine.frequency(for: "yearly goals"), .yearly)
        XCTAssertEqual(RecurrenceEngine.frequency(for: "annual planning"), .yearly)
    }

    func testFrequencyReturnsUnknownForEmptyOrUnmatched() {
        XCTAssertEqual(RecurrenceEngine.frequency(for: nil), .unknown)
        XCTAssertEqual(RecurrenceEngine.frequency(for: ""), .unknown)
        XCTAssertEqual(RecurrenceEngine.frequency(for: "   "), .unknown)
        XCTAssertEqual(RecurrenceEngine.frequency(for: "random text"), .unknown)
    }

    // MARK: nextOccurrence

    func testNextOccurrenceDailyAddsOneDay() {
        let cal = Self.calendar()
        let n = Self.now()
        let next = RecurrenceEngine.nextOccurrence(after: n, tag: "daily", calendar: cal)
        XCTAssertEqual(next, cal.date(byAdding: .day, value: 1, to: n))
    }

    func testNextOccurrenceWeeklyAddsOneWeek() {
        let cal = Self.calendar()
        let n = Self.now()
        let next = RecurrenceEngine.nextOccurrence(after: n, tag: "weekly review", calendar: cal)
        XCTAssertEqual(next, cal.date(byAdding: .weekOfYear, value: 1, to: n))
    }

    func testNextOccurrenceBiweeklyAddsTwoWeeks() {
        let cal = Self.calendar()
        let n = Self.now()
        let next = RecurrenceEngine.nextOccurrence(after: n, tag: "biweekly 1:1", calendar: cal)
        XCTAssertEqual(next, cal.date(byAdding: .weekOfYear, value: 2, to: n))
    }

    func testNextOccurrenceMonthlyAddsOneMonth() {
        let cal = Self.calendar()
        let n = Self.now()
        let next = RecurrenceEngine.nextOccurrence(after: n, tag: "monthly report", calendar: cal)
        XCTAssertEqual(next, cal.date(byAdding: .month, value: 1, to: n))
    }

    func testNextOccurrenceMonthlyHandlesMonthLengthCorrectly() {
        let cal = Self.calendar()
        // Jan 31 + 1 month = Feb 28 (not Mar 3) when using Calendar.date(byAdding:).
        let jan31 = cal.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 10))!
        let next = RecurrenceEngine.nextOccurrence(after: jan31, tag: "monthly", calendar: cal)
        let comps = cal.dateComponents([.year, .month, .day], from: next!)
        XCTAssertEqual(comps.month, 2)
        XCTAssertEqual(comps.day, 28)
    }

    func testNextOccurrenceUnknownTagFallsBackToDaily() {
        let cal = Self.calendar()
        let n = Self.now()
        let next = RecurrenceEngine.nextOccurrence(after: n, tag: "random", calendar: cal)
        XCTAssertEqual(next, cal.date(byAdding: .day, value: 1, to: n))
    }
}

// MARK: - SlotPreviewCache tests

@MainActor
final class SlotPreviewCacheTests: XCTestCase {

    func testFingerprintChangesWithTaskCount() {
        let a = BacklogTask(id: "a", title: "a", durationMinutes: 30)
        let b = BacklogTask(id: "b", title: "b", durationMinutes: 30)
        let fp1 = SlotPreviewCache.fingerprint(tasks: [a], eventCount: 0)
        let fp2 = SlotPreviewCache.fingerprint(tasks: [a, b], eventCount: 0)
        XCTAssertNotEqual(fp1, fp2)
    }

    func testFingerprintChangesWithDuration() {
        var a = BacklogTask(id: "a", title: "a", durationMinutes: 30)
        let fp1 = SlotPreviewCache.fingerprint(tasks: [a], eventCount: 0)
        a.durationMinutes = 60
        let fp2 = SlotPreviewCache.fingerprint(tasks: [a], eventCount: 0)
        XCTAssertNotEqual(fp1, fp2)
    }

    func testFingerprintChangesWithEventCount() {
        let a = BacklogTask(id: "a", title: "a", durationMinutes: 30)
        let fp1 = SlotPreviewCache.fingerprint(tasks: [a], eventCount: 0)
        let fp2 = SlotPreviewCache.fingerprint(tasks: [a], eventCount: 1)
        XCTAssertNotEqual(fp1, fp2)
    }

    func testInvalidateIfChangedClearsEntriesOnNewFingerprint() async {
        let cache = SlotPreviewCache()
        // Seed a direct cache entry so we don't rely on the async compute path.
        let formatted = SlotPreviewCache.format(slot: nil)
        XCTAssertEqual(formatted.label, "no free slot this week")

        cache.invalidateIfChanged(to: 1)
        cache.invalidateIfChanged(to: 2)
        // Same value again — should be a no-op, not throw.
        cache.invalidateIfChanged(to: 2)
    }

    func testFormatEmptySlotReturnsNoSlotLabel() {
        let r = SlotPreviewCache.format(slot: nil)
        XCTAssertEqual(r.label, "no free slot this week")
        XCTAssertNil(r.slot)
    }

    func testFormatSlotIncludesTimeRange() {
        let start = Date()
        let interval = DateInterval(start: start, duration: 30 * 60)
        let r = SlotPreviewCache.format(slot: interval)
        XCTAssertNotNil(r.slot)
        XCTAssertTrue(r.label.contains(":"), "Formatted label must contain a time separator")
    }
}

// MARK: - EditTaskView dependency filter tests

final class EditTaskViewFilterTests: XCTestCase {

    private func task(_ id: String, title: String, context: String? = nil) -> BacklogTask {
        BacklogTask(id: id, title: title, durationMinutes: 60, priority: .medium, context: context)
    }

    func testEmptyQueryReturnsAll() {
        let tasks = [task("a", title: "Alpha"), task("b", title: "Beta")]
        let result = EditTaskView.filterDependencyCandidates(tasks, query: "")
        XCTAssertEqual(result.map(\.id), ["a", "b"])
    }

    func testSubstringMatchesTitle() {
        let tasks = [task("a", title: "Write spec"), task("b", title: "Review PR")]
        let result = EditTaskView.filterDependencyCandidates(tasks, query: "spec")
        XCTAssertEqual(result.map(\.id), ["a"])
    }

    func testSubstringMatchesContext() {
        let tasks = [
            task("a", title: "Alpha", context: "Backend"),
            task("b", title: "Beta", context: "UI"),
        ]
        let result = EditTaskView.filterDependencyCandidates(tasks, query: "back")
        XCTAssertEqual(result.map(\.id), ["a"])
    }

    func testSearchIsCaseInsensitive() {
        let tasks = [task("a", title: "Ship QA bundle")]
        let result = EditTaskView.filterDependencyCandidates(tasks, query: "SHIP")
        XCTAssertEqual(result.map(\.id), ["a"])
    }

    func testWhitespaceOnlyQueryReturnsAll() {
        let tasks = [task("a", title: "Alpha"), task("b", title: "Beta")]
        let result = EditTaskView.filterDependencyCandidates(tasks, query: "   ")
        XCTAssertEqual(result.map(\.id), ["a", "b"])
    }
}

// MARK: - Recurring completeTask integration tests

@MainActor
final class BacklogServiceRecurringTests: XCTestCase {

    private var service: BacklogService!

    override func setUp() async throws {
        try await super.setUp()
        let container = try ModelContainer(
            for: PersistedBacklogTask.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        service = BacklogService(modelContainer: container)
    }

    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }

    func testCompleteRecurringTaskAdvancesDeadline() {
        var task = BacklogTask(
            id: "r",
            title: "weekly review",
            durationMinutes: 30,
            priority: .medium,
            isRecurring: true,
            recurrenceTag: "weekly"
        )
        task.deadline = Date()
        service.addTask(task)

        service.completeTask(id: "r")

        let updated = service.tasks.first { $0.id == "r" }
        XCTAssertEqual(updated?.status, .pending, "Recurring task should stay active")
        XCTAssertNotNil(updated?.deadline, "Recurring task should have a deadline after completion")
        if let before = task.deadline, let after = updated?.deadline {
            XCTAssertGreaterThan(after, before, "Deadline should advance to a future date")
        }
    }

    func testCompleteNonRecurringTaskDoesNotTouchDeadline() {
        var task = BacklogTask(id: "t", title: "one-off", durationMinutes: 30)
        let originalDeadline = Date().addingTimeInterval(86_400)
        task.deadline = originalDeadline
        service.addTask(task)

        service.completeTask(id: "t")

        let updated = service.tasks.first { $0.id == "t" }
        XCTAssertEqual(updated?.status, .done)
        XCTAssertEqual(updated?.deadline, originalDeadline)
    }
}

// MARK: - Incremental persistence tests

@MainActor
final class BacklogServicePersistenceTests: XCTestCase {

    private var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: PersistedBacklogTask.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    func testAddAndLoadRoundTrip() {
        let service = BacklogService(modelContainer: container)
        service.addTask(BacklogTask(id: "a", title: "Alpha", durationMinutes: 30))
        service.addTask(BacklogTask(id: "b", title: "Beta", durationMinutes: 60))

        // New service instance reads through SwiftData — exercises the
        // incremental save path's round-trip from the writer's perspective.
        let reader = BacklogService(modelContainer: container)
        XCTAssertEqual(reader.tasks.map(\.id), ["a", "b"])
        XCTAssertEqual(reader.tasks.map(\.title), ["Alpha", "Beta"])
    }

    func testUpdatePreservesOtherRows() {
        let service = BacklogService(modelContainer: container)
        service.addTask(BacklogTask(id: "a", title: "Alpha", durationMinutes: 30))
        service.addTask(BacklogTask(id: "b", title: "Beta", durationMinutes: 60))

        var updated = service.tasks.first { $0.id == "a" }!
        updated.title = "Alpha Prime"
        service.updateTask(updated)

        let reader = BacklogService(modelContainer: container)
        XCTAssertEqual(reader.tasks.first { $0.id == "a" }?.title, "Alpha Prime")
        XCTAssertEqual(reader.tasks.first { $0.id == "b" }?.title, "Beta")
    }

    func testRemovePersists() {
        let service = BacklogService(modelContainer: container)
        service.addTask(BacklogTask(id: "a", title: "Alpha"))
        service.addTask(BacklogTask(id: "b", title: "Beta"))

        _ = service.removeTask(id: "a")

        let reader = BacklogService(modelContainer: container)
        XCTAssertEqual(reader.tasks.map(\.id), ["b"])
    }

    func testReorderPersistsSortOrder() {
        let service = BacklogService(modelContainer: container)
        service.addTask(BacklogTask(id: "a", title: "Alpha"))
        service.addTask(BacklogTask(id: "b", title: "Beta"))
        service.addTask(BacklogTask(id: "c", title: "Gamma"))

        service.moveTask(id: "c", before: "a")

        let reader = BacklogService(modelContainer: container)
        XCTAssertEqual(reader.tasks.map(\.id), ["c", "a", "b"])
    }

    func testUpdateStampsModifiedAt() {
        let service = BacklogService(modelContainer: container)
        let task = BacklogTask(id: "a", title: "Alpha", durationMinutes: 30)
        service.addTask(task)
        XCTAssertNil(service.tasks.first?.modifiedAt)

        var updated = service.tasks.first!
        updated.durationMinutes = 45
        service.updateTask(updated)

        XCTAssertNotNil(service.tasks.first?.modifiedAt,
                        "updateTask should stamp modifiedAt for iCloud conflict resolution")
    }

    func testUpdateSkipsNoOpChanges() {
        let service = BacklogService(modelContainer: container)
        let task = BacklogTask(id: "a", title: "Alpha", durationMinutes: 30)
        service.addTask(task)

        // First real update stamps modifiedAt.
        var updated = service.tasks.first!
        updated.durationMinutes = 45
        service.updateTask(updated)
        let firstStamp = service.tasks.first?.modifiedAt
        XCTAssertNotNil(firstStamp)

        // Identical update should NOT bump modifiedAt — callers like the
        // edit-row autosave fire on every keystroke, and we don't want to
        // churn CloudKit traffic when nothing really changed.
        let echo = service.tasks.first!
        service.updateTask(echo)
        XCTAssertEqual(service.tasks.first?.modifiedAt, firstStamp,
                       "No-op updateTask must not rewrite modifiedAt")
    }

    func testRemovePreservesOtherSortOrder() {
        let service = BacklogService(modelContainer: container)
        service.addTask(BacklogTask(id: "a", title: "Alpha"))
        service.addTask(BacklogTask(id: "b", title: "Beta"))
        service.addTask(BacklogTask(id: "c", title: "Gamma"))

        _ = service.removeTask(id: "b")

        let reader = BacklogService(modelContainer: container)
        XCTAssertEqual(reader.tasks.map(\.id), ["a", "c"],
                       "Remaining tasks must keep their relative order")
    }

    func testCompleteTaskPersistsStatusTransition() {
        let service = BacklogService(modelContainer: container)
        service.addTask(BacklogTask(id: "a", title: "Alpha"))
        service.completeTask(id: "a")

        let reader = BacklogService(modelContainer: container)
        XCTAssertEqual(reader.tasks.first?.status, .done)
    }

    func testMoveTaskToEndPersistsSortOrder() {
        let service = BacklogService(modelContainer: container)
        service.addTask(BacklogTask(id: "a", title: "Alpha"))
        service.addTask(BacklogTask(id: "b", title: "Beta"))
        service.addTask(BacklogTask(id: "c", title: "Gamma"))

        service.moveTaskToEnd(id: "a")

        let reader = BacklogService(modelContainer: container)
        XCTAssertEqual(reader.tasks.map(\.id), ["b", "c", "a"])
    }

    func testFreezeTaskPersists() {
        let service = BacklogService(modelContainer: container)
        service.addTask(BacklogTask(id: "a", title: "Alpha"))

        service.freezeTask(id: "a")

        let reader = BacklogService(modelContainer: container)
        XCTAssertEqual(reader.tasks.first?.status, .frozen)
    }

    func testRestoreTaskAtIndexKeepsSortOrderConsistent() {
        let service = BacklogService(modelContainer: container)
        let b = BacklogTask(id: "b", title: "Beta")
        service.addTask(BacklogTask(id: "a", title: "Alpha"))
        service.addTask(b)
        service.addTask(BacklogTask(id: "c", title: "Gamma"))

        _ = service.removeTask(id: "b")
        service.restoreTask(b, at: 1)

        let reader = BacklogService(modelContainer: container)
        XCTAssertEqual(reader.tasks.map(\.id), ["a", "b", "c"])
    }
}
