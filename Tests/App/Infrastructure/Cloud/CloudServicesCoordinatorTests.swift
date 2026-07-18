import XCTest
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - CloudServicesCoordinator Tests
//
// Two layers of coverage:
//
//  1. Pure-logic tests exercise `summary(...)` and `isWarning(...)` as
//     static functions. Every state combination (disabled, idle, syncing,
//     errored, quota warning, signed-out) is asserted directly — no
//     monitor/KV instantiation needed.
//
//  2. Instance tests verify that `start(containerIdentifier:)` fans out
//     to both transports and flips `isRunning`, using
//     `FakeCloudKitSyncMonitor` + `FakeCloudKeyValueSync`.

@MainActor
final class CloudServicesCoordinatorTests: XCTestCase {

    // MARK: - Disabled State

    func testSummaryIsDisabledWhenNotRunning() {
        let s = CloudServicesCoordinator.summary(
            isRunning: false,
            cloudKitLastError: nil,
            cloudKitPhase: .idle,
            cloudKitSummary: "anything",
            kvStatus: .idle
        )
        XCTAssertEqual(s, "Disabled")
    }

    func testIsWarningIsFalseWhenNotRunning() {
        XCTAssertFalse(CloudServicesCoordinator.isWarning(
            isRunning: false,
            cloudKitLastError: "some error",
            kvStatus: .unavailable
        ), "the Disabled state should never warn — it's explicit opt-out")
    }

    // MARK: - Error Precedence

    func testCloudKitErrorWinsOverEverything() {
        let s = CloudServicesCoordinator.summary(
            isRunning: true,
            cloudKitLastError: "CK error",
            cloudKitPhase: .importing,
            cloudKitSummary: "Downloading…",
            kvStatus: .synced(Date())
        )
        XCTAssertEqual(s, "CK error")
    }

    func testKVErrorWinsOverPhase() {
        // No CloudKit error, but KV errored → KV message beats the
        // in-flight phase summary.
        let s = CloudServicesCoordinator.summary(
            isRunning: true,
            cloudKitLastError: nil,
            cloudKitPhase: .importing,
            cloudKitSummary: "Downloading…",
            kvStatus: .error("KV crashed")
        )
        XCTAssertEqual(s, "KV crashed")
    }

    // MARK: - In-flight Phase

    func testCloudKitPhaseShowsPhaseSummary() {
        for phase in [CloudKitSyncPhase.setup, .importing, .exporting] {
            let s = CloudServicesCoordinator.summary(
                isRunning: true,
                cloudKitLastError: nil,
                cloudKitPhase: phase,
                cloudKitSummary: "Phase \(phase)",
                kvStatus: .idle
            )
            XCTAssertEqual(s, "Phase \(phase)")
        }
    }

    // MARK: - Idle Combinations

    func testIdlePhaseFallsBackToCloudKitSummary() {
        let s = CloudServicesCoordinator.summary(
            isRunning: true,
            cloudKitLastError: nil,
            cloudKitPhase: .idle,
            cloudKitSummary: "Synced 5m ago",
            kvStatus: .idle
        )
        XCTAssertEqual(s, "Synced 5m ago")
    }

    func testIdlePhaseWithSyncedKVFallsBackToCloudKitSummary() {
        let s = CloudServicesCoordinator.summary(
            isRunning: true,
            cloudKitLastError: nil,
            cloudKitPhase: .idle,
            cloudKitSummary: "Synced 5m ago",
            kvStatus: .synced(Date())
        )
        XCTAssertEqual(s, "Synced 5m ago")
    }

    // MARK: - KV-specific messages

    func testQuotaWarningShowsKBCount() {
        let s = CloudServicesCoordinator.summary(
            isRunning: true,
            cloudKitLastError: nil,
            cloudKitPhase: .idle,
            cloudKitSummary: "unused",
            kvStatus: .quotaWarning(usedBytes: 900_000)
        )
        XCTAssertTrue(s.contains("KV approaching quota"), "got: \(s)")
        XCTAssertTrue(s.contains("878"), "900_000 / 1024 = 878 KB; got: \(s)")
    }

    func testKVUnavailableShowsSignedOutMessage() {
        let s = CloudServicesCoordinator.summary(
            isRunning: true,
            cloudKitLastError: nil,
            cloudKitPhase: .idle,
            cloudKitSummary: "unused",
            kvStatus: .unavailable
        )
        XCTAssertEqual(s, "Not signed in to iCloud")
    }

    // MARK: - Warning Flag

    func testIsWarningOnCloudKitError() {
        XCTAssertTrue(CloudServicesCoordinator.isWarning(
            isRunning: true,
            cloudKitLastError: "any error",
            kvStatus: .idle
        ))
    }

    func testIsWarningOnKVError() {
        XCTAssertTrue(CloudServicesCoordinator.isWarning(
            isRunning: true,
            cloudKitLastError: nil,
            kvStatus: .error("boom")
        ))
    }

    func testIsWarningOnKVQuota() {
        XCTAssertTrue(CloudServicesCoordinator.isWarning(
            isRunning: true,
            cloudKitLastError: nil,
            kvStatus: .quotaWarning(usedBytes: 900_000)
        ))
    }

    func testIsWarningFalseOnHappyPath() {
        XCTAssertFalse(CloudServicesCoordinator.isWarning(
            isRunning: true,
            cloudKitLastError: nil,
            kvStatus: .synced(Date())
        ))
    }

    // MARK: - Instance / Injection

    func testStartFansOutToBothTransports() {
        let monitor = FakeCloudKitSyncMonitor()
        let kv = FakeCloudKeyValueSync()
        let coord = CloudServicesCoordinator(cloudKit: monitor, keyValue: kv)

        XCTAssertFalse(coord.isRunning)

        coord.start(containerIdentifier: "iCloud.com.example.test")

        XCTAssertTrue(coord.isRunning)
        XCTAssertEqual(monitor.startInvocations, ["iCloud.com.example.test"])
        XCTAssertEqual(kv.performInitialSyncCallCount, 1)
    }

    func testStartIsIdempotentlyCallable() {
        let monitor = FakeCloudKitSyncMonitor()
        let kv = FakeCloudKeyValueSync()
        let coord = CloudServicesCoordinator(cloudKit: monitor, keyValue: kv)

        coord.start(containerIdentifier: "a")
        coord.start(containerIdentifier: "a")

        // The coordinator fans out on every call — idempotence lives in
        // the underlying concrete services (AppContainer calls start()
        // only once). Assert we got two invocations, not one, so the
        // fan-out is unambiguous.
        XCTAssertEqual(monitor.startInvocations.count, 2)
        XCTAssertEqual(kv.performInitialSyncCallCount, 2)
        XCTAssertTrue(coord.isRunning)
    }

    func testInstanceSummaryMirrorsPureLogic() {
        let monitor = FakeCloudKitSyncMonitor(
            phase: .importing,
            lastError: nil,
            summary: "Downloading…"
        )
        let kv = FakeCloudKeyValueSync(status: .idle)
        let coord = CloudServicesCoordinator(cloudKit: monitor, keyValue: kv)
        // The coordinator's start takes a non-optional identifier
        // (only the underlying monitor accepts nil-as-default).
        coord.start(containerIdentifier: "iCloud.test")

        XCTAssertEqual(coord.summary, "Downloading…")
        XCTAssertFalse(coord.isWarning)
    }
}
