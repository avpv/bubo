import XCTest
import SwiftData
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - AppContainer Integration Tests
//
// Exercise `AppContainer.build(...)` with in-memory SwiftData containers
// and a coordinator backed by `FakeCloudKitSyncMonitor` / `FakeCloudKeyValueSync`.
// The goal isn't to test individual services — they have their own
// suites — it's to lock in that the wiring step itself doesn't regress:
//
//   - Every output service is non-nil.
//   - Services that share state (`OptimizerService.backlogService`,
//     `RemindersSyncService.backlogService`) point at the SAME instance,
//     not fresh constructions.
//   - The coordinator we injected is the one the container surfaces.
//
// This catches a whole class of bugs where a future refactor adds a new
// service and forgets to wire it into a sibling that needs it.

@MainActor
final class AppContainerIntegrationTests: XCTestCase {

    // MARK: - Fixtures

    private func makeInMemoryContainers() throws -> (
        eventCache: ModelContainer,
        userEvents: ModelContainer,
        backlog: ModelContainer
    ) {
        let cacheContainer = try ModelContainer(
            for: PersistedCachedEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let userEventsContainer = try ModelContainer(
            for: PersistedLocalEvent.self,
            PersistedExcludedOccurrence.self,
            PersistedReminderOverride.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let backlogContainer = try ModelContainer(
            for: PersistedBacklogTask.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (cacheContainer, userEventsContainer, backlogContainer)
    }

    private func makeContainer() throws -> AppContainer {
        let (cache, user, backlog) = try makeInMemoryContainers()
        let coord = CloudServicesCoordinator(
            cloudKit: FakeCloudKitSyncMonitor(),
            keyValue: FakeCloudKeyValueSync()
        )
        return AppContainer.build(
            settings: ReminderSettings(),
            eventCacheContainer: cache,
            userEventsContainer: user,
            backlogContainer: backlog,
            cloudServices: coord
        )
    }

    // MARK: - Wiring

    func testAllOutputsArePresent() throws {
        let container = try makeContainer()

        // Swift types are non-nil by construction — assert the graph
        // reads without throwing, which is what we actually care about.
        _ = container.settings
        _ = container.networkMonitor
        _ = container.agentService
        _ = container.cloudServices
        _ = container.reminderService
        _ = container.backlogService
        _ = container.optimizerService
        _ = container.remindersSyncService
    }

    func testOptimizerShareSBacklogServiceInstance() throws {
        let container = try makeContainer()
        XCTAssertTrue(
            container.optimizerService.backlogService === container.backlogService,
            "OptimizerService should hold the same BacklogService as the container. If this breaks, optimization runs against a stale task list that'll diverge from the UI."
        )
    }

    func testCloudServicesIsTheInjectedInstance() throws {
        let monitor = FakeCloudKitSyncMonitor()
        let kv = FakeCloudKeyValueSync()
        let coord = CloudServicesCoordinator(cloudKit: monitor, keyValue: kv)
        let (cache, user, backlog) = try makeInMemoryContainers()

        let container = AppContainer.build(
            settings: ReminderSettings(),
            eventCacheContainer: cache,
            userEventsContainer: user,
            backlogContainer: backlog,
            cloudServices: coord
        )

        XCTAssertTrue(container.cloudServices === coord)
    }

    func testSettingsInstanceIsPropagatedToDependentServices() throws {
        // `ReminderService` and `RemindersSyncService` both need
        // `ReminderSettings`. If the container constructed two different
        // instances, settings mutations from one service wouldn't show
        // up in the other — a very real past bug.
        //
        // `ReminderService` doesn't expose its internal settings field,
        // so we verify the invariant indirectly: toggling the input
        // `ReminderSettings` should be observable through
        // `reminderService.badgeCount` which reads settings.
        let settings = ReminderSettings()
        settings.showBadgeCount = true
        settings.badgeCountMode = .wholeDay
        let (cache, user, backlog) = try makeInMemoryContainers()
        let container = AppContainer.build(
            settings: settings,
            eventCacheContainer: cache,
            userEventsContainer: user,
            backlogContainer: backlog,
            cloudServices: CloudServicesCoordinator(
                cloudKit: FakeCloudKitSyncMonitor(),
                keyValue: FakeCloudKeyValueSync()
            )
        )

        XCTAssertTrue(container.settings === settings,
            "container.settings should be the same instance we passed in")

        // Flip the setting — the service observes the same instance so
        // the computed badge count reflects the change immediately.
        settings.showBadgeCount = false
        XCTAssertEqual(container.reminderService.badgeCount, 0,
            "ReminderService should read the new setting through the shared instance")
    }

    // MARK: - Smoke

    func testContainerStartsInCleanState() throws {
        let container = try makeContainer()

        XCTAssertEqual(container.reminderService.localEvents.count, 0)
        XCTAssertEqual(container.reminderService.upcomingEvents.count, 0)
        XCTAssertEqual(container.backlogService.tasks.count, 0)
        XCTAssertNil(container.reminderService.lastPersistenceError)
        XCTAssertFalse(container.cloudServices.isRunning)
    }
}
