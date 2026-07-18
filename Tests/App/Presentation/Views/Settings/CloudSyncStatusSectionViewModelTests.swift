import XCTest
import SwiftData
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - CloudSyncStatusSectionViewModel Tests
//
// Covers the three projections the VM is responsible for:
//   - isRestartPending (toggle vs launch-time snapshot)
//   - isSyncInProgress (coordinator phase + running flag)
//   - statusText / statusIsWarning pass-through
//
// The coordinator is driven with FakeCloudKitSyncMonitor +
// FakeCloudKeyValueSync so every state can be constructed deterministically.

@MainActor
final class CloudSyncStatusSectionViewModelTests: XCTestCase {

    // MARK: - Fixtures

    // nil defaults resolved in the body: the fakes are @MainActor and
    // default-argument expressions are evaluated in a nonisolated
    // context on this toolchain, so `= FakeCloudKitSyncMonitor()`
    // doesn't compile even though the test class itself is @MainActor.
    private func makeCoordinator(
        monitor: FakeCloudKitSyncMonitor? = nil,
        kv: FakeCloudKeyValueSync? = nil,
        running: Bool = false
    ) -> CloudServicesCoordinator {
        let coord = CloudServicesCoordinator(
            cloudKit: monitor ?? FakeCloudKitSyncMonitor(),
            keyValue: kv ?? FakeCloudKeyValueSync()
        )
        if running { coord.start(containerIdentifier: nil) }
        return coord
    }

    // The VM needs a `ReminderService.lastPersistenceError` — we pass
    // the raw optional instead of instantiating the service, because
    // the VM contract takes the projection already resolved.

    private func makeVM(
        cloudSyncEnabled: Bool,
        launchTimeCloudSyncEnabled: Bool,
        coordinator: CloudServicesCoordinator,
        persistenceError: String? = nil
    ) -> CloudSyncStatusSectionViewModel {
        CloudSyncStatusSectionViewModel(
            cloudSyncEnabled: cloudSyncEnabled,
            launchTimeCloudSyncEnabled: launchTimeCloudSyncEnabled,
            cloud: coordinator,
            persistenceError: persistenceError
        )
    }

    // MARK: - Restart Pending

    func testRestartNotPendingWhenFlagUnchanged() {
        let vm = makeVM(
            cloudSyncEnabled: false,
            launchTimeCloudSyncEnabled: false,
            coordinator: makeCoordinator()
        )
        XCTAssertFalse(vm.isRestartPending)
    }

    func testRestartPendingWhenUserTogglesOn() {
        let vm = makeVM(
            cloudSyncEnabled: true,
            launchTimeCloudSyncEnabled: false,
            coordinator: makeCoordinator()
        )
        XCTAssertTrue(vm.isRestartPending)
    }

    func testRestartPendingWhenUserTogglesOff() {
        let vm = makeVM(
            cloudSyncEnabled: false,
            launchTimeCloudSyncEnabled: true,
            coordinator: makeCoordinator()
        )
        XCTAssertTrue(vm.isRestartPending)
    }

    // MARK: - Sync In Progress

    func testSyncInProgressFalseWhenNotRunning() {
        let monitor = FakeCloudKitSyncMonitor(phase: .importing)
        let vm = makeVM(
            cloudSyncEnabled: true,
            launchTimeCloudSyncEnabled: true,
            coordinator: makeCoordinator(monitor: monitor, running: false)
        )
        XCTAssertFalse(vm.isSyncInProgress, "not running → no spinner regardless of phase")
    }

    func testSyncInProgressFalseWhenIdle() {
        let monitor = FakeCloudKitSyncMonitor(phase: .idle)
        let vm = makeVM(
            cloudSyncEnabled: true,
            launchTimeCloudSyncEnabled: true,
            coordinator: makeCoordinator(monitor: monitor, running: true)
        )
        XCTAssertFalse(vm.isSyncInProgress)
    }

    func testSyncInProgressTrueWhenImportingAndRunning() {
        let monitor = FakeCloudKitSyncMonitor(phase: .importing)
        let vm = makeVM(
            cloudSyncEnabled: true,
            launchTimeCloudSyncEnabled: true,
            coordinator: makeCoordinator(monitor: monitor, running: true)
        )
        XCTAssertTrue(vm.isSyncInProgress)
    }

    // MARK: - Status Pass-Through

    func testStatusTextIsDisabledBeforeStart() {
        let vm = makeVM(
            cloudSyncEnabled: false,
            launchTimeCloudSyncEnabled: false,
            coordinator: makeCoordinator(running: false)
        )
        XCTAssertEqual(vm.statusText, "Disabled")
        XCTAssertFalse(vm.statusIsWarning)
    }

    func testStatusWarningSurfacesCloudKitError() {
        let monitor = FakeCloudKitSyncMonitor(
            phase: .idle,
            lastError: "CloudKit failed to authorize",
            summary: "CloudKit failed to authorize"
        )
        let vm = makeVM(
            cloudSyncEnabled: true,
            launchTimeCloudSyncEnabled: true,
            coordinator: makeCoordinator(monitor: monitor, running: true)
        )
        XCTAssertEqual(vm.statusText, "CloudKit failed to authorize")
        XCTAssertTrue(vm.statusIsWarning)
    }

    // MARK: - Persistence Error Pass-Through

    func testPersistenceErrorIsNilWhenAbsent() {
        let vm = makeVM(
            cloudSyncEnabled: true,
            launchTimeCloudSyncEnabled: true,
            coordinator: makeCoordinator(running: true)
        )
        XCTAssertNil(vm.persistenceError)
    }

    func testPersistenceErrorBubbles() {
        let vm = makeVM(
            cloudSyncEnabled: true,
            launchTimeCloudSyncEnabled: true,
            coordinator: makeCoordinator(running: true),
            persistenceError: "disk full"
        )
        XCTAssertEqual(vm.persistenceError, "disk full")
    }
}
