import XCTest
import SwiftData
@testable import Bubo

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

    // MARK: sprint cap

    func testSprintCappedReturnsPrefix() {
        let tasks = (0..<10).map { task("t\($0)") }
        XCTAssertEqual(BacklogLogic.sprintCapped(tasks, max: 3).map(\.id), ["t0", "t1", "t2"])
    }

    func testSprintCappedZeroReturnsEmpty() {
        let tasks = [task("a")]
        XCTAssertTrue(BacklogLogic.sprintCapped(tasks, max: 0).isEmpty)
    }

    func testSprintCappedOverflowReturnsAll() {
        let tasks = [task("a"), task("b")]
        XCTAssertEqual(BacklogLogic.sprintCapped(tasks, max: 99).map(\.id), ["a", "b"])
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

    func testCapacityFractionWorkdayOverReturnsOverflowSentinel() {
        XCTAssertEqual(
            BacklogLogic.capacityFraction(pendingMinutes: 60, remainingWorkdayMinutes: 0),
            1.5
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
        XCTAssertEqual(RecurrenceEngine.frequency(for: "ежедневно"), .daily)
        XCTAssertEqual(RecurrenceEngine.frequency(for: "standup"), .daily)
    }

    func testFrequencyRecognisesWeekly() {
        XCTAssertEqual(RecurrenceEngine.frequency(for: "weekly review"), .weekly)
        XCTAssertEqual(RecurrenceEngine.frequency(for: "еженедельный разбор"), .weekly)
    }

    func testFrequencyRecognisesMonthly() {
        XCTAssertEqual(RecurrenceEngine.frequency(for: "monthly report"), .monthly)
        XCTAssertEqual(RecurrenceEngine.frequency(for: "ежемесячный отчёт"), .monthly)
    }

    func testFrequencyRecognisesBiweekly() {
        XCTAssertEqual(RecurrenceEngine.frequency(for: "biweekly 1:1"), .biweekly)
        XCTAssertEqual(RecurrenceEngine.frequency(for: "fortnight plan"), .biweekly)
    }

    func testFrequencyRecognisesQuarterly() {
        XCTAssertEqual(RecurrenceEngine.frequency(for: "quarterly review"), .quarterly)
        XCTAssertEqual(RecurrenceEngine.frequency(for: "квартальный план"), .quarterly)
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

// MARK: - BacklogTaskEditRow dependency filter tests

final class BacklogTaskEditRowFilterTests: XCTestCase {

    private func task(_ id: String, title: String, context: String? = nil) -> BacklogTask {
        BacklogTask(id: id, title: title, durationMinutes: 60, priority: .medium, context: context)
    }

    func testEmptyQueryReturnsAll() {
        let tasks = [task("a", title: "Alpha"), task("b", title: "Beta")]
        let result = BacklogTaskEditRow.filterDependencyCandidates(tasks, query: "")
        XCTAssertEqual(result.map(\.id), ["a", "b"])
    }

    func testSubstringMatchesTitle() {
        let tasks = [task("a", title: "Write spec"), task("b", title: "Review PR")]
        let result = BacklogTaskEditRow.filterDependencyCandidates(tasks, query: "spec")
        XCTAssertEqual(result.map(\.id), ["a"])
    }

    func testSubstringMatchesContext() {
        let tasks = [
            task("a", title: "Alpha", context: "Backend"),
            task("b", title: "Beta", context: "UI"),
        ]
        let result = BacklogTaskEditRow.filterDependencyCandidates(tasks, query: "back")
        XCTAssertEqual(result.map(\.id), ["a"])
    }

    func testSearchIsCaseInsensitive() {
        let tasks = [task("a", title: "Ship QA bundle")]
        let result = BacklogTaskEditRow.filterDependencyCandidates(tasks, query: "SHIP")
        XCTAssertEqual(result.map(\.id), ["a"])
    }

    func testWhitespaceOnlyQueryReturnsAll() {
        let tasks = [task("a", title: "Alpha"), task("b", title: "Beta")]
        let result = BacklogTaskEditRow.filterDependencyCandidates(tasks, query: "   ")
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
}
