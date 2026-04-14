import XCTest
@testable import Bubo

// MARK: - Task Conflict Resolution Tests

final class TaskConflictResolutionTests: XCTestCase {

    private let now = Date()
    private lazy var yesterday: Date = now.addingTimeInterval(-86400)
    private lazy var twoDaysAgo: Date = now.addingTimeInterval(-2 * 86400)

    private func task(
        id: String = "t1",
        status: BacklogStatus = .pending,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        completedAt: Date? = nil,
        scheduledDate: Date? = nil,
        title: String = "Task"
    ) -> BacklogTask {
        var t = BacklogTask(
            id: id,
            title: title,
            createdAt: createdAt ?? twoDaysAgo
        )
        t.status = status
        t.modifiedAt = modifiedAt
        t.completedAt = completedAt
        t.scheduledDate = scheduledDate
        return t
    }

    // MARK: - Done always wins

    func testDoneBeatsScheduled() {
        let local = task(status: .done, completedAt: yesterday)
        let remote = task(status: .scheduled, scheduledDate: now)
        let winner = CloudSyncService.resolveTaskConflict(local: local, remote: remote)
        XCTAssertEqual(winner.status, .done)
    }

    func testDoneBeatsPending() {
        let local = task(status: .pending, modifiedAt: now)
        let remote = task(status: .done, completedAt: yesterday)
        let winner = CloudSyncService.resolveTaskConflict(local: local, remote: remote)
        XCTAssertEqual(winner.status, .done)
    }

    func testBothDoneTakesLaterTimestamp() {
        let local = task(status: .done, completedAt: yesterday, modifiedAt: yesterday)
        let remote = task(status: .done, completedAt: now, modifiedAt: now)
        let winner = CloudSyncService.resolveTaskConflict(local: local, remote: remote)
        XCTAssertEqual(winner.completedAt, now)
    }

    // MARK: - Scheduled beats pending

    func testScheduledBeatsPending() {
        let local = task(status: .scheduled, scheduledDate: now)
        let remote = task(status: .pending, modifiedAt: now)
        let winner = CloudSyncService.resolveTaskConflict(local: local, remote: remote)
        XCTAssertEqual(winner.status, .scheduled)
    }

    func testScheduledBeatsPendingReverse() {
        let local = task(status: .pending)
        let remote = task(status: .scheduled, scheduledDate: yesterday)
        let winner = CloudSyncService.resolveTaskConflict(local: local, remote: remote)
        XCTAssertEqual(winner.status, .scheduled)
    }

    // MARK: - modifiedAt decides same-status conflicts

    func testSameStatusUsesModifiedAt() {
        let local = task(status: .pending, modifiedAt: yesterday, title: "Old title")
        let remote = task(status: .pending, modifiedAt: now, title: "New title")
        let winner = CloudSyncService.resolveTaskConflict(local: local, remote: remote)
        XCTAssertEqual(winner.title, "New title")
    }

    func testSameStatusLocalWinsWhenNewer() {
        let local = task(status: .pending, modifiedAt: now, title: "Local")
        let remote = task(status: .pending, modifiedAt: yesterday, title: "Remote")
        let winner = CloudSyncService.resolveTaskConflict(local: local, remote: remote)
        XCTAssertEqual(winner.title, "Local")
    }

    // MARK: - Fallback timestamps when modifiedAt is nil

    func testFallsBackToCreatedAtWhenNoModifiedAt() {
        let local = task(status: .pending, createdAt: yesterday)
        let remote = task(status: .pending, createdAt: now)
        let winner = CloudSyncService.resolveTaskConflict(local: local, remote: remote)
        XCTAssertEqual(winner.createdAt, now)
    }

    func testFallsBackToScheduledDate() {
        let local = task(status: .scheduled, scheduledDate: yesterday)
        let remote = task(status: .scheduled, scheduledDate: now)
        let winner = CloudSyncService.resolveTaskConflict(local: local, remote: remote)
        XCTAssertEqual(winner.scheduledDate, now)
    }

    func testMixedTimestampFallback() {
        // Local has modifiedAt, remote only has createdAt
        let local = task(status: .pending, createdAt: twoDaysAgo, modifiedAt: now)
        let remote = task(status: .pending, createdAt: yesterday)
        let winner = CloudSyncService.resolveTaskConflict(local: local, remote: remote)
        XCTAssertEqual(winner.modifiedAt, now, "modifiedAt should win over createdAt")
    }
}

// MARK: - Backlog Merge Tests

final class BacklogMergeTests: XCTestCase {

    private let now = Date()
    private lazy var yesterday: Date = now.addingTimeInterval(-86400)

    private func task(
        id: String,
        title: String = "Task",
        status: BacklogStatus = .pending,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil
    ) -> BacklogTask {
        var t = BacklogTask(id: id, title: title, createdAt: createdAt ?? now)
        t.status = status
        t.modifiedAt = modifiedAt
        return t
    }

    // MARK: - Union semantics

    func testLocalOnlyTasksKept() {
        let local = [task(id: "a"), task(id: "b")]
        let remote: [BacklogTask] = []
        let merged = CloudSyncService.mergeBacklogTasks(
            local: local, remote: remote, tombstones: []
        )
        XCTAssertEqual(merged.map(\.id), ["a", "b"])
    }

    func testRemoteOnlyTasksAppended() {
        let local: [BacklogTask] = []
        let remote = [task(id: "x"), task(id: "y")]
        let merged = CloudSyncService.mergeBacklogTasks(
            local: local, remote: remote, tombstones: []
        )
        XCTAssertEqual(merged.map(\.id), ["x", "y"])
    }

    func testUnionMerge() {
        let local = [task(id: "a"), task(id: "b")]
        let remote = [task(id: "b"), task(id: "c")]
        let merged = CloudSyncService.mergeBacklogTasks(
            local: local, remote: remote, tombstones: []
        )
        XCTAssertEqual(merged.map(\.id), ["a", "b", "c"])
    }

    func testLocalOrderingPreserved() {
        let local = [task(id: "c"), task(id: "a"), task(id: "b")]
        let remote = [task(id: "a"), task(id: "d")]
        let merged = CloudSyncService.mergeBacklogTasks(
            local: local, remote: remote, tombstones: []
        )
        // c, a, b from local order; d appended from remote
        XCTAssertEqual(merged.map(\.id), ["c", "a", "b", "d"])
    }

    // MARK: - Conflict resolution in merge

    func testConflictResolutionDuringMerge() {
        let local = [task(id: "t1", title: "Old", modifiedAt: yesterday)]
        let remote = [task(id: "t1", title: "New", modifiedAt: now)]
        let merged = CloudSyncService.mergeBacklogTasks(
            local: local, remote: remote, tombstones: []
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].title, "New")
    }

    // MARK: - Tombstones

    func testTombstoneExcludesLocalTask() {
        let local = [task(id: "a"), task(id: "b")]
        let remote: [BacklogTask] = []
        let merged = CloudSyncService.mergeBacklogTasks(
            local: local, remote: remote, tombstones: ["a"]
        )
        XCTAssertEqual(merged.map(\.id), ["b"])
    }

    func testTombstoneExcludesRemoteTask() {
        let local: [BacklogTask] = []
        let remote = [task(id: "x"), task(id: "y")]
        let merged = CloudSyncService.mergeBacklogTasks(
            local: local, remote: remote, tombstones: ["y"]
        )
        XCTAssertEqual(merged.map(\.id), ["x"])
    }

    func testTombstoneExcludesBothSides() {
        let local = [task(id: "a"), task(id: "b")]
        let remote = [task(id: "b"), task(id: "c")]
        let merged = CloudSyncService.mergeBacklogTasks(
            local: local, remote: remote, tombstones: ["b"]
        )
        XCTAssertEqual(merged.map(\.id), ["a", "c"])
    }

    func testEmptyTombstonesNoEffect() {
        let local = [task(id: "a")]
        let remote = [task(id: "b")]
        let merged = CloudSyncService.mergeBacklogTasks(
            local: local, remote: remote, tombstones: []
        )
        XCTAssertEqual(merged.map(\.id), ["a", "b"])
    }

    // MARK: - Edge cases

    func testBothEmpty() {
        let merged = CloudSyncService.mergeBacklogTasks(
            local: [], remote: [], tombstones: []
        )
        XCTAssertTrue(merged.isEmpty)
    }

    func testDuplicateIDsInRemote() {
        // Remote has the same ID twice (shouldn't happen but be safe)
        let local = [task(id: "a")]
        let remote = [
            task(id: "b", title: "First"),
            task(id: "b", title: "Second"),
        ]
        let merged = CloudSyncService.mergeBacklogTasks(
            local: local, remote: remote, tombstones: []
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.id), ["a", "b"])
    }

    func testAllTombstoned() {
        let local = [task(id: "a"), task(id: "b")]
        let remote = [task(id: "a"), task(id: "b")]
        let merged = CloudSyncService.mergeBacklogTasks(
            local: local, remote: remote, tombstones: ["a", "b"]
        )
        XCTAssertTrue(merged.isEmpty)
    }
}

// MARK: - Energy Check-In Merge Tests

final class EnergyCheckInMergeTests: XCTestCase {

    private func checkIn(
        hoursAgo: Double,
        energyLevel: Int = 3,
        hour: Int = 10
    ) -> EnergyCheckInService.CheckIn {
        EnergyCheckInService.CheckIn(
            timestamp: Date().addingTimeInterval(-hoursAgo * 3600),
            energyLevel: energyLevel,
            dayOfWeek: 2,
            hour: hour,
            meetingCount: 0
        )
    }

    func testUnionByTimestamp() {
        let local = [checkIn(hoursAgo: 2), checkIn(hoursAgo: 4)]
        let remote = [checkIn(hoursAgo: 3), checkIn(hoursAgo: 5)]
        let merged = CloudSyncService.mergeEnergyCheckIns(
            local: local, remote: remote
        )
        XCTAssertEqual(merged.count, 4, "All unique check-ins should be kept")
    }

    func testDeduplicationByTimestamp() {
        let ci = checkIn(hoursAgo: 1)
        let merged = CloudSyncService.mergeEnergyCheckIns(
            local: [ci], remote: [ci]
        )
        XCTAssertEqual(merged.count, 1, "Duplicate should be removed")
    }

    func testChronologicalOrder() {
        let old = checkIn(hoursAgo: 48)
        let recent = checkIn(hoursAgo: 1)
        let merged = CloudSyncService.mergeEnergyCheckIns(
            local: [recent], remote: [old]
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssert(
            merged[0].timestamp < merged[1].timestamp,
            "Should be sorted chronologically"
        )
    }

    func testRetention90Days() {
        let old = EnergyCheckInService.CheckIn(
            timestamp: Date().addingTimeInterval(-100 * 86400), // 100 days ago
            energyLevel: 3,
            dayOfWeek: 2,
            hour: 10,
            meetingCount: 0
        )
        let recent = checkIn(hoursAgo: 1)
        let merged = CloudSyncService.mergeEnergyCheckIns(
            local: [old], remote: [recent]
        )
        XCTAssertEqual(merged.count, 1, "Entries older than 90 days pruned")
        XCTAssertEqual(merged[0].energyLevel, recent.energyLevel)
    }

    func testBothEmpty() {
        let merged = CloudSyncService.mergeEnergyCheckIns(local: [], remote: [])
        XCTAssertTrue(merged.isEmpty)
    }
}

// MARK: - String Array Merge Tests

final class StringArrayMergeTests: XCTestCase {

    func testSetUnion() {
        let local = ["a", "b", "c"]
        let remote = ["b", "c", "d"]
        let merged = CloudSyncService.mergeStringArrays(
            local: local, remote: remote
        )
        XCTAssertEqual(Set(merged), Set(["a", "b", "c", "d"]))
    }

    func testEmptyLocal() {
        let merged = CloudSyncService.mergeStringArrays(
            local: [], remote: ["x"]
        )
        XCTAssertEqual(merged, ["x"])
    }

    func testEmptyRemote() {
        let merged = CloudSyncService.mergeStringArrays(
            local: ["x"], remote: []
        )
        XCTAssertEqual(merged, ["x"])
    }

    func testBothEmpty() {
        let merged = CloudSyncService.mergeStringArrays(local: [], remote: [])
        XCTAssertTrue(merged.isEmpty)
    }

    func testIdenticalArrays() {
        let merged = CloudSyncService.mergeStringArrays(
            local: ["a", "b"], remote: ["a", "b"]
        )
        XCTAssertEqual(Set(merged), Set(["a", "b"]))
    }
}

// MARK: - BacklogTask modifiedAt Codable Tests

final class BacklogTaskModifiedAtTests: XCTestCase {

    func testModifiedAtRoundTrips() throws {
        let now = Date()
        var task = BacklogTask(id: "t1", title: "Test", createdAt: now)
        task.modifiedAt = now

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(BacklogTask.self, from: data)

        XCTAssertEqual(decoded.modifiedAt, now)
    }

    func testModifiedAtNilWhenMissing() throws {
        // Simulate old data without modifiedAt
        var task = BacklogTask(id: "t1", title: "Test")
        task.modifiedAt = nil

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(BacklogTask.self, from: data)

        XCTAssertNil(decoded.modifiedAt)
    }

    func testOldDataWithoutModifiedAtField() throws {
        // JSON from a version before modifiedAt existed
        let json = """
        {
            "id": "t1",
            "title": "Legacy task",
            "durationMinutes": 60,
            "priority": "medium",
            "dependsOn": [],
            "status": "pending",
            "createdAt": 0
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BacklogTask.self, from: data)

        XCTAssertEqual(decoded.id, "t1")
        XCTAssertEqual(decoded.title, "Legacy task")
        XCTAssertNil(decoded.modifiedAt)
    }
}

// MARK: - Schema Version Tests

final class SchemaVersionTests: XCTestCase {

    func testSchemaVersionIsPositive() {
        XCTAssertGreaterThan(CloudSyncService.schemaVersion, 0)
    }

    func testSyncedKeysNonEmpty() {
        XCTAssertFalse(CloudSyncService.syncedKeys.isEmpty)
    }

    func testExpectedKeysPresent() {
        let keys = CloudSyncService.syncedKeys
        XCTAssertTrue(keys.contains("ReminderSettings"))
        XCTAssertTrue(keys.contains("BuboBacklogTasks"))
        XCTAssertTrue(keys.contains("BuboOptimizerLearnedWeights"))
        XCTAssertTrue(keys.contains("BuboEnergyCheckIns"))
    }

    func testTombstoneKeyNotInSyncedKeys() {
        // Tombstones are managed separately from regular synced keys.
        XCTAssertFalse(
            CloudSyncService.syncedKeys.contains(CloudSyncService.tombstoneKey)
        )
    }
}
