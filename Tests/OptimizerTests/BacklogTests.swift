import XCTest
import SwiftData
@testable import Bubo

final class BacklogTaskTests: XCTestCase {

    // MARK: - Task Creation

    func testDefaultTaskValues() {
        let task = BacklogTask(title: "Test")
        XCTAssertEqual(task.title, "Test")
        XCTAssertEqual(task.durationMinutes, 60)
        XCTAssertEqual(task.priority, .medium)
        XCTAssertEqual(task.status, .pending)
        XCTAssertNil(task.deadline)
        XCTAssertNil(task.storyPoints)
        XCTAssertNil(task.context)
        XCTAssertNil(task.scheduledEventId)
        XCTAssertTrue(task.dependsOn.isEmpty)
    }

    func testTaskWithAllProperties() {
        let deadline = Date().addingTimeInterval(86400)
        let task = BacklogTask(
            title: "Complex Task",
            durationMinutes: 120,
            priority: .high,
            deadline: deadline,
            storyPoints: 8,
            context: "Project X",
            dependsOn: ["dep-1", "dep-2"],
            preferredPeriod: .morning
        )
        XCTAssertEqual(task.durationMinutes, 120)
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.storyPoints, 8)
        XCTAssertEqual(task.context, "Project X")
        XCTAssertEqual(task.dependsOn, ["dep-1", "dep-2"])
        XCTAssertEqual(task.preferredPeriod, .morning)
    }

    // MARK: - Priority

    func testPriorityNumericValues() {
        XCTAssertEqual(TaskPriority.low.numericValue, 0.3)
        XCTAssertEqual(TaskPriority.medium.numericValue, 0.5)
        XCTAssertEqual(TaskPriority.high.numericValue, 0.9)
    }

    // MARK: - Conversion to OptimizableEvent

    func testToOptimizableEvent() {
        let task = BacklogTask(
            id: "task-1",
            title: "Write report",
            durationMinutes: 90,
            priority: .high,
            context: "Reports",
            preferredPeriod: .morning
        )
        let event = task.toOptimizableEvent()

        XCTAssertEqual(event.id, "task-1")
        XCTAssertEqual(event.title, "Write report")
        XCTAssertEqual(event.duration, 5400)  // 90 * 60
        XCTAssertEqual(event.priority, 0.9)
        XCTAssertEqual(event.context, "Reports")
        XCTAssertEqual(event.preferredHourRange, 6...12)  // morning
        XCTAssertFalse(event.isFocusBlock)
    }

    func testToOptimizableEventWithDeadline() {
        let deadline = Date().addingTimeInterval(86400)
        let task = BacklogTask(
            title: "Urgent",
            deadline: deadline,
            storyPoints: 5
        )
        let event = task.toOptimizableEvent()

        XCTAssertEqual(event.deadline, deadline)
        XCTAssertEqual(event.storyPoints, 5)
        // Energy should be adjusted for story points
        XCTAssertGreaterThan(event.energyCost, 0.3)
    }

    // MARK: - Oversized Task Auto-Chunking

    func testSplitOversizedLeavesFittingTaskAlone() {
        let event = OptimizableEvent(
            id: "short",
            title: "Short task",
            duration: TimeInterval(5 * 3600),
            isDroppable: true
        )
        let result = IntentCompiler.splitOversizedBacklogTasks([event], workingHours: 9...18)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "short")
        XCTAssertEqual(result[0].duration, TimeInterval(5 * 3600))
    }

    func testSplitOversizedSplitsLongTaskIntoEqualParts() {
        // 12h task with a 9h working window → ceil(12/9) = 2 parts of 6h each.
        let event = OptimizableEvent(
            id: "big",
            title: "Big task",
            duration: TimeInterval(12 * 3600),
            priority: 0.9,
            context: "Deep work",
            isDroppable: true,
            backlogIndex: 3
        )
        let result = IntentCompiler.splitOversizedBacklogTasks([event], workingHours: 9...18)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, "big_p0")
        XCTAssertEqual(result[1].id, "big_p1")
        XCTAssertEqual(result[0].title, "Big task (1/2)")
        XCTAssertEqual(result[1].title, "Big task (2/2)")
        XCTAssertEqual(result[0].duration, TimeInterval(6 * 3600))
        XCTAssertEqual(result[1].duration, TimeInterval(6 * 3600))
        // Order enforced by sequential dependsOn chain.
        XCTAssertTrue(result[0].dependsOn.isEmpty)
        XCTAssertEqual(result[1].dependsOn, ["big_p0"])
        // Priority / context / droppability / backlog position propagate.
        XCTAssertEqual(result[0].priority, 0.9)
        XCTAssertEqual(result[1].context, "Deep work")
        XCTAssertTrue(result[0].isDroppable)
        XCTAssertTrue(result[1].isDroppable)
        XCTAssertEqual(result[0].backlogIndex, 3)
        XCTAssertEqual(result[1].backlogIndex, 3)
        // Atomic group: both parts share the source task id so
        // AtomicGroupConstraint treats them as one drop-or-keep unit.
        XCTAssertEqual(result[0].groupId, "big")
        XCTAssertEqual(result[1].groupId, "big")
    }

    func testSplitOversizedPreservesExistingDependsOnOnFirstPart() {
        let event = OptimizableEvent(
            id: "chain",
            title: "Chained task",
            duration: TimeInterval(20 * 3600),
            dependsOn: ["upstream"]
        )
        let result = IntentCompiler.splitOversizedBacklogTasks([event], workingHours: 9...18)

        // ceil(20/9) = 3 parts.
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].dependsOn, ["upstream"])
        XCTAssertEqual(result[1].dependsOn, ["chain_p0"])
        XCTAssertEqual(result[2].dependsOn, ["chain_p1"])
    }

    func testSplitOversizedIsNoOpWhenWindowIsDegenerate() {
        let event = OptimizableEvent(
            id: "x",
            title: "x",
            duration: TimeInterval(10 * 3600)
        )
        // upperBound == lowerBound → no positive window, bail out.
        let result = IntentCompiler.splitOversizedBacklogTasks([event], workingHours: 9...9)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "x")
    }

    // MARK: - Codable

    func testTaskCodable() throws {
        let task = BacklogTask(
            title: "Codable Test",
            durationMinutes: 45,
            priority: .low,
            storyPoints: 3,
            context: "Testing"
        )
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(BacklogTask.self, from: data)

        XCTAssertEqual(decoded.title, task.title)
        XCTAssertEqual(decoded.durationMinutes, task.durationMinutes)
        XCTAssertEqual(decoded.priority, task.priority)
        XCTAssertEqual(decoded.storyPoints, task.storyPoints)
        XCTAssertEqual(decoded.context, task.context)
    }

    // MARK: - Adjusted Energy

    func testAdjustedEnergy() {
        // No story points → base energy unchanged
        XCTAssertEqual(adjustedEnergy(base: 0.5, storyPoints: nil), 0.5)
        XCTAssertEqual(adjustedEnergy(base: 0.5, storyPoints: 0), 0.5)

        // High story points → higher energy
        let highSP = adjustedEnergy(base: 0.5, storyPoints: 13)
        XCTAssertGreaterThan(highSP, 0.5)

        // Low story points → lower energy boost
        let lowSP = adjustedEnergy(base: 0.5, storyPoints: 1)
        XCTAssertLessThan(lowSP, highSP)
    }
}

// MARK: - BacklogService Tests

/// Exercises the reorder + cross-context surface introduced for
/// drag-to-schedule / drag-to-reorder. Uses UserDefaults.standard because the
/// service hard-codes that key; we scrub the key in setUp/tearDown so test
/// runs can't leak state into a developer's live install.
@MainActor
final class BacklogServiceTests: XCTestCase {

    /// Legacy UserDefaults key used before BacklogService moved to SwiftData.
    /// Kept around as defensive scrubbing so a developer running tests on
    /// a machine with a live Bubo install doesn't leak pre-v1.10 state
    /// into the live app — the key is otherwise unused.
    private static let persistenceKey = "BuboBacklogTasks"

    private var savedState: Data?
    private var service: BacklogService!

    override func setUp() async throws {
        try await super.setUp()
        savedState = UserDefaults.standard.data(forKey: Self.persistenceKey)
        UserDefaults.standard.removeObject(forKey: Self.persistenceKey)

        // In-memory container with the backlog schema registered so the
        // service's targeted persist paths can round-trip cleanly.
        let container = try ModelContainer(
            for: PersistedBacklogTask.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        service = BacklogService(modelContainer: container)
    }

    override func tearDown() async throws {
        service = nil
        if let savedState {
            UserDefaults.standard.set(savedState, forKey: Self.persistenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.persistenceKey)
        }
        savedState = nil
        try await super.tearDown()
    }

    // MARK: Helpers

    @discardableResult
    private func addTask(
        _ title: String,
        context: String? = nil,
        priority: TaskPriority = .medium
    ) -> BacklogTask {
        let task = BacklogTask(
            id: "task-\(title)",
            title: title,
            durationMinutes: 60,
            priority: priority,
            context: context
        )
        service.addTask(task)
        return task
    }

    private func activeIds() -> [String] {
        service.tasks.filter { $0.status != .done }.map(\.id)
    }

    // MARK: markScheduled

    func testMarkScheduledSingleEventKeepsListAndPrimaryInSync() {
        addTask("single")
        service.markScheduled(id: "task-single", eventId: "evt-1", date: Date())

        let updated = service.tasks.first { $0.id == "task-single" }
        XCTAssertEqual(updated?.status, .scheduled)
        XCTAssertEqual(updated?.scheduledEventId, "evt-1")
        XCTAssertEqual(updated?.scheduledEventIds, ["evt-1"])
    }

    func testMarkScheduledMultiEventPersistsEveryChunkId() {
        // Mirrors the auto-chunk path: one BacklogTask, N CalendarEvents,
        // one `markScheduled` call with the full list.
        addTask("big")
        let ids = ["big_p0", "big_p1", "big_p2"]
        service.markScheduled(id: "task-big", eventIds: ids, date: Date())

        let updated = service.tasks.first { $0.id == "task-big" }
        XCTAssertEqual(updated?.scheduledEventIds, ids)
        XCTAssertEqual(updated?.scheduledEventId, "big_p0")
        XCTAssertEqual(updated?.status, .scheduled)
    }

    func testMarkScheduledNoOpWhenEventIdsEmpty() {
        addTask("ghost")
        service.markScheduled(id: "task-ghost", eventIds: [], date: Date())

        let updated = service.tasks.first { $0.id == "task-ghost" }
        XCTAssertEqual(updated?.status, .pending)
        XCTAssertNil(updated?.scheduledEventId)
        XCTAssertTrue(updated?.scheduledEventIds.isEmpty ?? false)
    }

    func testUnscheduleClearsBothPrimaryAndList() {
        addTask("clear")
        service.markScheduled(id: "task-clear", eventIds: ["a", "b"], date: Date())
        service.unschedule(id: "task-clear")

        let updated = service.tasks.first { $0.id == "task-clear" }
        XCTAssertEqual(updated?.status, .pending)
        XCTAssertNil(updated?.scheduledEventId)
        XCTAssertTrue(updated?.scheduledEventIds.isEmpty ?? false)
    }

    func testPersistedTaskRoundTripsEventIds() throws {
        // Make sure the new `scheduledEventIdsData` column survives an
        // encode/decode pass and legacy rows (no list) still produce a
        // non-empty list derived from the singular id.
        addTask("rt")
        service.markScheduled(id: "task-rt", eventIds: ["e0", "e1", "e2"], date: Date())

        let source = service.tasks.first { $0.id == "task-rt" }!
        let persisted = PersistedBacklogTask(from: source, sortOrder: 0)
        let restored = persisted.toBacklogTask()
        XCTAssertEqual(restored.scheduledEventIds, ["e0", "e1", "e2"])
        XCTAssertEqual(restored.scheduledEventId, "e0")

        // Legacy path: a row saved before this field existed has
        // `scheduledEventIdsData == nil` but still points at a single
        // event through the legacy column.
        persisted.scheduledEventIdsData = nil
        let legacy = persisted.toBacklogTask()
        XCTAssertEqual(legacy.scheduledEventIds, ["e0"])
    }

    // MARK: indexOfTask

    func testIndexOfTaskReturnsCurrentPosition() {
        addTask("a")
        addTask("b")
        addTask("c")

        XCTAssertEqual(service.indexOfTask(id: "task-a"), 0)
        XCTAssertEqual(service.indexOfTask(id: "task-b"), 1)
        XCTAssertEqual(service.indexOfTask(id: "task-c"), 2)
        XCTAssertNil(service.indexOfTask(id: "nonexistent"))
    }

    // MARK: moveTask(id:before:)

    func testMoveTaskBeforeReordersStorage() {
        addTask("a")
        addTask("b")
        addTask("c")
        addTask("d")

        service.moveTask(id: "task-c", before: "task-a")

        XCTAssertEqual(activeIds(), ["task-c", "task-a", "task-b", "task-d"])
    }

    func testMoveTaskBeforeIsNoOpWhenTargetEqualsMoved() {
        addTask("a")
        addTask("b")

        service.moveTask(id: "task-a", before: "task-a")

        XCTAssertEqual(activeIds(), ["task-a", "task-b"])
    }

    func testMoveTaskBeforeIsNoOpForUnknownId() {
        addTask("a")
        addTask("b")

        service.moveTask(id: "ghost", before: "task-a")

        XCTAssertEqual(activeIds(), ["task-a", "task-b"])
    }

    // MARK: moveTaskToEnd

    func testMoveTaskToEndAppendsRegardlessOfPriority() {
        addTask("a", priority: .low)
        addTask("b", priority: .high)
        addTask("c", priority: .medium)

        service.moveTaskToEnd(id: "task-b")

        XCTAssertEqual(activeIds(), ["task-a", "task-c", "task-b"])
    }

    // MARK: pin / unpin

    func testPinTaskAssignsRankZeroAndShowsInSmartSort() {
        addTask("a")
        addTask("b")

        service.pinTask(id: "task-b")

        let pinned = service.tasks.first { $0.id == "task-b" }
        XCTAssertEqual(pinned?.pinnedRank, 0)

        let sorted = BacklogLogic.smartSorted(service.tasks)
        XCTAssertEqual(sorted.map(\.id).first, "task-b")
    }

    func testPinningSecondTaskShiftsExistingPinDown() {
        addTask("a")
        addTask("b")

        service.pinTask(id: "task-a")
        service.pinTask(id: "task-b") // newest pin → top

        let a = service.tasks.first { $0.id == "task-a" }
        let b = service.tasks.first { $0.id == "task-b" }
        XCTAssertEqual(b?.pinnedRank, 0)
        XCTAssertEqual(a?.pinnedRank, 1)
    }

    func testPinTaskBeforeUnpinnedAppendsToPinTail() {
        addTask("a")
        addTask("b")
        addTask("c")
        // a is pinned at rank 0; b stays unpinned. Pinning c "before b" must
        // put c at the end of the pinned list (rank 1) so c sits above b
        // without dethroning a.
        service.pinTask(id: "task-a")
        service.pinTask(id: "task-c", before: "task-b")

        let a = service.tasks.first { $0.id == "task-a" }
        let c = service.tasks.first { $0.id == "task-c" }
        XCTAssertEqual(a?.pinnedRank, 0)
        XCTAssertEqual(c?.pinnedRank, 1)

        let sorted = BacklogLogic.smartSorted(service.tasks).map(\.id)
        XCTAssertEqual(sorted.prefix(2).map { $0 }, ["task-a", "task-c"])
    }

    func testUnpinTaskRenumbersRemainingPins() {
        addTask("a")
        addTask("b")
        addTask("c")
        service.pinTask(id: "task-a")
        service.pinTask(id: "task-b")
        service.pinTask(id: "task-c") // ranks: c=0, b=1, a=2

        service.unpinTask(id: "task-b")

        let a = service.tasks.first { $0.id == "task-a" }
        let b = service.tasks.first { $0.id == "task-b" }
        let c = service.tasks.first { $0.id == "task-c" }
        XCTAssertEqual(c?.pinnedRank, 0)
        XCTAssertEqual(a?.pinnedRank, 1)
        XCTAssertNil(b?.pinnedRank)
    }

    func testUnpinAllClearsEveryPin() {
        addTask("a")
        addTask("b")
        service.pinTask(id: "task-a")
        service.pinTask(id: "task-b")

        service.unpinAll()

        XCTAssertNil(service.tasks.first { $0.id == "task-a" }?.pinnedRank)
        XCTAssertNil(service.tasks.first { $0.id == "task-b" }?.pinnedRank)
    }

    // MARK: restoreTask(_:at:)

    func testRestoreTaskAtIndexPutsBackAtSamePosition() {
        addTask("a")
        let b = addTask("b")
        addTask("c")

        let originalIndex = service.indexOfTask(id: "task-b")
        _ = service.removeTask(id: "task-b")
        XCTAssertEqual(activeIds(), ["task-a", "task-c"])

        service.restoreTask(b, at: originalIndex)
        XCTAssertEqual(activeIds(), ["task-a", "task-b", "task-c"])
    }

    func testRestoreTaskFallsBackToAppendOnOutOfRangeIndex() {
        addTask("a")
        let b = addTask("b")

        _ = service.removeTask(id: "task-b")
        service.restoreTask(b, at: 99)

        XCTAssertEqual(activeIds().last, "task-b")
    }

    func testRestoreTaskFallsBackToAppendWhenIndexIsNil() {
        addTask("a")
        let b = addTask("b")

        _ = service.removeTask(id: "task-b")
        service.restoreTask(b, at: nil)

        XCTAssertEqual(activeIds(), ["task-a", "task-b"])
    }

    // MARK: groupedByContext

    func testGroupedByContextPreservesStorageOrderWithinGroup() {
        // Alphabetical sort by deadline/priority would put C first; we
        // want the user's drag-ordered sequence to win instead.
        addTask("c", context: "Project X", priority: .high)
        addTask("a", context: "Project X", priority: .low)
        addTask("b", context: "Project X", priority: .medium)

        let grouped = service.groupedByContext
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].tasks.map(\.id), ["task-c", "task-a", "task-b"])
    }

    func testGroupedByContextPushesNoContextBucketLast() {
        addTask("untagged-1", context: nil)
        addTask("tagged-1", context: "Alpha")
        addTask("untagged-2", context: nil)
        addTask("tagged-2", context: "Beta")

        let contexts = service.groupedByContext.map(\.context)
        // Expect: tagged groups first (first-seen order), nil bucket last.
        XCTAssertEqual(contexts, ["Alpha", "Beta", nil])
    }

    func testGroupedByContextReflectsReorderAcrossContexts() {
        let projA = addTask("p-a", context: "A")
        addTask("p-b", context: "B")
        addTask("p-a2", context: "A")

        // Cross-context drop: update context then move.
        var updated = projA
        updated.context = "B"
        service.updateTask(updated)
        service.moveTask(id: projA.id, before: "task-p-b")

        let grouped = service.groupedByContext
        // Group B now contains projA (newly reassigned) first, then p-b.
        let bGroup = grouped.first(where: { $0.context == "B" })
        XCTAssertNotNil(bGroup)
        XCTAssertEqual(bGroup?.tasks.map(\.id), ["task-p-a", "task-p-b"])

        // Group A still has p-a2.
        let aGroup = grouped.first(where: { $0.context == "A" })
        XCTAssertEqual(aGroup?.tasks.map(\.id), ["task-p-a2"])
    }

    // MARK: carryOverUnfinished

    func testCarryOverUnfinishedUnschedulesPastTasksOnly() {
        addTask("future")
        addTask("past")

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        service.markScheduled(id: "task-past", eventId: "event-past", date: yesterday)

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        service.markScheduled(id: "task-future", eventId: "event-future", date: tomorrow)

        service.carryOverUnfinished()

        let past = service.tasks.first(where: { $0.id == "task-past" })
        let future = service.tasks.first(where: { $0.id == "task-future" })
        XCTAssertEqual(past?.status, .pending)
        XCTAssertNil(past?.scheduledEventId)
        XCTAssertEqual(future?.status, .scheduled)
        XCTAssertEqual(future?.scheduledEventId, "event-future")
    }
}

// MARK: - BacklogTitleParser Tests

final class BacklogTitleParserTests: XCTestCase {

    func testReturnsCleanedTitleAndMinutesForTrailingMinutes() {
        let r = BacklogTitleParser.parse("write report 90m")
        XCTAssertEqual(r.cleaned, "write report")
        XCTAssertEqual(r.durationMinutes, 90)
    }

    func testReturnsCleanedTitleForTrailingHours() {
        let r = BacklogTitleParser.parse("design sync 1h")
        XCTAssertEqual(r.cleaned, "design sync")
        XCTAssertEqual(r.durationMinutes, 60)
    }

    func testCombinesHoursAndMinutes() {
        let r = BacklogTitleParser.parse("deep work 1h30m")
        XCTAssertEqual(r.cleaned, "deep work")
        XCTAssertEqual(r.durationMinutes, 90)
    }

    func testRecognisesMinSpelling() {
        let r = BacklogTitleParser.parse("review PR 45 min")
        XCTAssertEqual(r.cleaned, "review PR")
        XCTAssertEqual(r.durationMinutes, 45)
    }

    func testRecognisesLongFormMinutes() {
        let r = BacklogTitleParser.parse("coffee 15 minutes")
        XCTAssertEqual(r.cleaned, "coffee")
        XCTAssertEqual(r.durationMinutes, 15)
    }

    func testIgnoresDurationInTheMiddleOfTitle() {
        // "30-minute" in the middle shouldn't be scooped up.
        let r = BacklogTitleParser.parse("30 minute standup with team")
        XCTAssertNil(r.durationMinutes)
        XCTAssertEqual(r.cleaned, "30 minute standup with team")
    }

    func testReturnsOriginalWhenNoMatch() {
        let r = BacklogTitleParser.parse("just a task")
        XCTAssertNil(r.durationMinutes)
        XCTAssertEqual(r.cleaned, "just a task")
    }

    func testHandlesEmptyInput() {
        let r = BacklogTitleParser.parse("")
        XCTAssertNil(r.durationMinutes)
        XCTAssertEqual(r.cleaned, "")
    }

    func testBareDurationKeepsOriginalAsTitle() {
        // "30m" on its own would leave nothing behind — we preserve the
        // original so the user doesn't end up with a blank task.
        let r = BacklogTitleParser.parse("30m")
        XCTAssertEqual(r.durationMinutes, 30)
        XCTAssertEqual(r.cleaned, "30m")
    }

    func testClampsEnormousDurations() {
        let r = BacklogTitleParser.parse("marathon 99999m")
        XCTAssertEqual(r.durationMinutes, 12 * 60)  // capped at 12h
    }

    func testClampsTinyDurations() {
        let r = BacklogTitleParser.parse("blink 1m")
        XCTAssertEqual(r.durationMinutes, 5)  // minimum 5m
    }
}

// MARK: - FreeSlotFinder nextSlot Tests

final class FreeSlotFinderTests: XCTestCase {

    /// Fixed "now" used by all tests so day boundaries are deterministic.
    private static func fixedNow() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(
            year: 2026, month: 4, day: 11,
            hour: 10, minute: 0, second: 0
        ))!
    }

    private static func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func event(
        id: String,
        startHour: Int,
        startMinute: Int,
        durationMinutes: Int,
        dayOffset: Int = 0,
        calendar: Calendar
    ) -> CalendarEvent {
        let base = calendar.date(byAdding: .day, value: dayOffset, to: Self.fixedNow())!
        let dayStart = calendar.startOfDay(for: base)
        let start = calendar.date(
            bySettingHour: startHour, minute: startMinute, second: 0, of: dayStart
        )!
        return CalendarEvent(
            id: id,
            title: id,
            startDate: start,
            endDate: start.addingTimeInterval(TimeInterval(durationMinutes * 60)),
            location: nil,
            description: nil,
            calendarName: nil,
            eventType: .standard,
            colorTag: nil
        )
    }

    func testNextSlotFindsTrailingGapToday() {
        let cal = Self.utcCalendar()
        let ev = event(id: "meeting", startHour: 11, startMinute: 0, durationMinutes: 60, calendar: cal)
        let slot = FreeSlotFinder.nextSlot(
            matching: 30,
            in: [ev],
            workingHours: 9...18,
            calendar: cal,
            now: Self.fixedNow()
        )
        XCTAssertNotNil(slot)
        // Working day is 9–18, now is 10:00, event is 11:00–12:00.
        // First gap is 10:00–11:00 (60 min). Ask for 30 min → start 10:00.
        XCTAssertEqual(slot?.start, Self.fixedNow())
        XCTAssertEqual(slot?.duration, 30 * 60)
    }

    func testNextSlotRollsOverToTomorrowWhenTodayFull() {
        let cal = Self.utcCalendar()
        // Cover the full working day with one long event.
        let fullDay = event(id: "all", startHour: 10, startMinute: 0, durationMinutes: 8 * 60, calendar: cal)
        let slot = FreeSlotFinder.nextSlot(
            matching: 60,
            in: [fullDay],
            workingHours: 9...18,
            maxDaysAhead: 3,
            calendar: cal,
            now: Self.fixedNow()
        )
        XCTAssertNotNil(slot)
        // Should land on tomorrow at 09:00.
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Self.fixedNow())!
        let tomorrowStart = cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.startOfDay(for: tomorrow))!
        XCTAssertEqual(slot?.start, tomorrowStart)
    }

    func testNextSlotReturnsNilWhenNothingFits() {
        let cal = Self.utcCalendar()
        let ev = event(id: "busy", startHour: 10, startMinute: 0, durationMinutes: 8 * 60, calendar: cal)
        let slot = FreeSlotFinder.nextSlot(
            matching: 120,
            in: [ev],
            workingHours: 9...11,  // narrow working window
            maxDaysAhead: 0,       // only today
            calendar: cal,
            now: Self.fixedNow()
        )
        XCTAssertNil(slot)
    }

    func testNextSlotSkipsGapsTooSmallForTask() {
        let cal = Self.utcCalendar()
        // Meeting at 10:30–11:30 leaves only a 30-min gap before it; that's
        // too small for a 60-min task, so the finder should jump to the
        // next usable gap after the meeting.
        let ev = event(id: "meeting", startHour: 10, startMinute: 30, durationMinutes: 60, calendar: cal)
        let slot = FreeSlotFinder.nextSlot(
            matching: 60,
            in: [ev],
            workingHours: 9...18,
            calendar: cal,
            now: Self.fixedNow()
        )
        XCTAssertNotNil(slot)
        // Expected: 11:30 start, exactly 60 min (task duration, not gap).
        let expectedStart = cal.date(
            bySettingHour: 11, minute: 30, second: 0,
            of: cal.startOfDay(for: Self.fixedNow())
        )!
        XCTAssertEqual(slot?.start, expectedStart)
        XCTAssertEqual(slot?.duration, 60 * 60)
    }
}
