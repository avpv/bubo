import XCTest
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

/// Covers the cross-device merge rules that protect monotonic fields
/// (completion, reminder link) from CloudKit's last-writer-wins row mirror,
/// and the hard cap on `BuboDismissedReminderIds` that keeps the unbounded
/// set from eating the 1 MB iCloud KV quota.
final class CloudSyncMergeTests: XCTestCase {

    // MARK: - BacklogTask.merged

    func testMergePrefersDoneOverStalePending() {
        // Device A completed the task at T=10. Device B then edited the
        // title at T=20, never seeing the completion. Without the
        // monotonic rule the newer "pending" edit would resurrect the task.
        var completed = BacklogTask(id: "t", title: "Original")
        completed.status = .done
        completed.completedAt = Date(timeIntervalSinceReferenceDate: 10)
        completed.modifiedAt = Date(timeIntervalSinceReferenceDate: 10)

        var edited = BacklogTask(id: "t", title: "Renamed")
        edited.status = .pending
        edited.modifiedAt = Date(timeIntervalSinceReferenceDate: 20)

        let merged = BacklogTask.merged(local: completed, remote: edited)

        XCTAssertEqual(merged.status, .done, "Completion must be monotonic")
        XCTAssertNotNil(merged.completedAt)
        XCTAssertEqual(merged.title, "Renamed", "Newer edit still wins on non-monotonic fields")
    }

    func testMergeAllowsRecurringReset() {
        // Recurring tasks legitimately move from .done back to .pending
        // after a cycle — the monotonic guard should skip them.
        var done = BacklogTask(
            id: "daily",
            title: "Daily standup",
            isRecurring: true,
            recurrenceTag: "daily"
        )
        done.status = .done
        done.completedAt = Date(timeIntervalSinceReferenceDate: 10)
        done.modifiedAt = Date(timeIntervalSinceReferenceDate: 10)

        var reset = done
        reset.status = .pending
        reset.completedAt = Date(timeIntervalSinceReferenceDate: 10)
        reset.modifiedAt = Date(timeIntervalSinceReferenceDate: 100)

        let merged = BacklogTask.merged(local: done, remote: reset)
        XCTAssertEqual(merged.status, .pending)
    }

    func testMergeKeepsNonNilReminderLink() {
        // A device that already created the Apple Reminders counterpart
        // learns about a stale remote edit that has no link. Without the
        // rule, the link would be dropped and the reminder duplicated on
        // the next export.
        var linked = BacklogTask(id: "t", title: "Write report")
        linked.reminderCalendarItemId = "reminder-42"
        linked.modifiedAt = Date(timeIntervalSinceReferenceDate: 10)

        var stale = BacklogTask(id: "t", title: "Write report")
        stale.reminderCalendarItemId = nil
        stale.modifiedAt = Date(timeIntervalSinceReferenceDate: 20)

        let merged = BacklogTask.merged(local: linked, remote: stale)
        XCTAssertEqual(merged.reminderCalendarItemId, "reminder-42")
    }

    func testMergeFallsBackToLastWriterOnOrdinaryFields() {
        var older = BacklogTask(id: "t", title: "Old")
        older.modifiedAt = Date(timeIntervalSinceReferenceDate: 10)
        var newer = BacklogTask(id: "t", title: "New")
        newer.modifiedAt = Date(timeIntervalSinceReferenceDate: 20)

        let merged = BacklogTask.merged(local: older, remote: newer)
        XCTAssertEqual(merged.title, "New")
    }

    // MARK: - CloudSyncService.mergeStringArrays cap

    func testStringArrayMergeUnderCap() {
        let merged = CloudSyncService.mergeStringArrays(
            local: ["a", "b"],
            remote: ["b", "c"],
            cap: 100
        )
        XCTAssertEqual(Set(merged), Set(["a", "b", "c"]))
    }

    func testStringArrayMergeAppliesCap() {
        let local = (0..<1500).map { "id-\($0)" }
        let remote = (1000..<2500).map { "id-\($0)" }
        let merged = CloudSyncService.mergeStringArrays(
            local: local,
            remote: remote,
            cap: 2000
        )
        XCTAssertEqual(merged.count, 2000)
        // Cap is deterministic (sorted prefix), so every device should
        // converge on the same trimmed set.
        let again = CloudSyncService.mergeStringArrays(
            local: remote,
            remote: local,
            cap: 2000
        )
        XCTAssertEqual(Set(merged), Set(again))
    }
}
