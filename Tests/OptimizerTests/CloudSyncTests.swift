import XCTest
@testable import Bubo

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
        XCTAssertEqual(merged.count, 4)
    }

    func testDeduplicationByTimestamp() {
        let ci = checkIn(hoursAgo: 1)
        let merged = CloudSyncService.mergeEnergyCheckIns(
            local: [ci], remote: [ci]
        )
        XCTAssertEqual(merged.count, 1)
    }

    func testChronologicalOrder() {
        let old = checkIn(hoursAgo: 48)
        let recent = checkIn(hoursAgo: 1)
        let merged = CloudSyncService.mergeEnergyCheckIns(
            local: [recent], remote: [old]
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssert(merged[0].timestamp < merged[1].timestamp)
    }

    func testRetention90Days() {
        let old = EnergyCheckInService.CheckIn(
            timestamp: Date().addingTimeInterval(-100 * 86400),
            energyLevel: 3,
            dayOfWeek: 2,
            hour: 10,
            meetingCount: 0
        )
        let recent = checkIn(hoursAgo: 1)
        let merged = CloudSyncService.mergeEnergyCheckIns(
            local: [old], remote: [recent]
        )
        XCTAssertEqual(merged.count, 1)
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

// MARK: - Schema & Config Tests

final class CloudSyncConfigTests: XCTestCase {

    func testSchemaVersionIsPositive() {
        XCTAssertGreaterThan(CloudSyncService.schemaVersion, 0)
    }

    func testSyncedKeysNonEmpty() {
        XCTAssertFalse(CloudSyncService.syncedKeys.isEmpty)
    }

    func testExpectedKeysPresent() {
        let keys = CloudSyncService.syncedKeys
        XCTAssertTrue(keys.contains("ReminderSettings"))
        XCTAssertTrue(keys.contains("BuboOptimizerLearnedWeights"))
        XCTAssertTrue(keys.contains("BuboEnergyCheckIns"))
    }

    func testBacklogTasksNotInKVStore() {
        // Tasks are synced via SwiftData + CloudKit, NOT the KV store.
        XCTAssertFalse(
            CloudSyncService.syncedKeys.contains("BuboBacklogTasks")
        )
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
        var task = BacklogTask(id: "t1", title: "Test")
        task.modifiedAt = nil

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(BacklogTask.self, from: data)

        XCTAssertNil(decoded.modifiedAt)
    }
}

// MARK: - PersistedBacklogTask Conversion Tests

final class PersistedBacklogTaskTests: XCTestCase {

    func testRoundTripConversion() {
        let now = Date()
        var task = BacklogTask(
            id: "t1",
            title: "Write report",
            durationMinutes: 90,
            priority: .high,
            deadline: now.addingTimeInterval(86400),
            storyPoints: 5,
            context: "Work",
            dependsOn: ["dep-1", "dep-2"],
            preferredPeriod: .morning,
            createdAt: now
        )
        task.status = .scheduled
        task.modifiedAt = now
        task.scheduledDate = now
        task.scheduledEventId = "event-1"

        let persisted = PersistedBacklogTask(from: task, sortOrder: 7.5)
        let back = persisted.toBacklogTask()

        XCTAssertEqual(back.id, "t1")
        XCTAssertEqual(back.title, "Write report")
        XCTAssertEqual(back.durationMinutes, 90)
        XCTAssertEqual(back.priority, .high)
        XCTAssertEqual(back.storyPoints, 5)
        XCTAssertEqual(back.context, "Work")
        XCTAssertEqual(back.dependsOn, ["dep-1", "dep-2"])
        XCTAssertEqual(back.preferredPeriod, .morning)
        XCTAssertEqual(back.status, .scheduled)
        XCTAssertEqual(back.scheduledEventId, "event-1")
        XCTAssertEqual(persisted.sortOrder, 7.5, accuracy: 0.001)
    }

    func testDefaultValues() {
        let task = BacklogTask(id: "t2", title: "Simple")
        let persisted = PersistedBacklogTask(from: task, sortOrder: 0)
        let back = persisted.toBacklogTask()

        XCTAssertEqual(back.id, "t2")
        XCTAssertEqual(back.durationMinutes, 60)
        XCTAssertEqual(back.priority, .medium)
        XCTAssertEqual(back.status, .pending)
        XCTAssertNil(back.deadline)
        XCTAssertNil(back.storyPoints)
        XCTAssertNil(back.context)
        XCTAssertTrue(back.dependsOn.isEmpty)
        XCTAssertNil(back.preferredPeriod)
    }

    func testUpdateFromTask() {
        let original = BacklogTask(id: "t1", title: "Old", priority: .low)
        let persisted = PersistedBacklogTask(from: original, sortOrder: 0)

        var updated = BacklogTask(id: "t1", title: "New", priority: .high)
        updated.status = .done
        updated.completedAt = Date()
        updated.modifiedAt = Date()

        persisted.update(from: updated)
        let back = persisted.toBacklogTask()

        XCTAssertEqual(back.title, "New")
        XCTAssertEqual(back.priority, .high)
        XCTAssertEqual(back.status, .done)
        XCTAssertNotNil(back.completedAt)
    }

    func testFractionalSortOrder() {
        let task = BacklogTask(id: "t1", title: "A")
        let persisted = PersistedBacklogTask(from: task, sortOrder: 1.5)
        XCTAssertEqual(persisted.sortOrder, 1.5, accuracy: 0.001)

        persisted.sortOrder = 1.25
        XCTAssertEqual(persisted.sortOrder, 1.25, accuracy: 0.001)
    }
}
