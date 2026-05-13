import Foundation
import SwiftData
import os
import BuboDomain

private let logger = Logger(subsystem: "com.avpv.Bubo", category: "AppContainer")

// MARK: - App Container (Composition Root)

/// Builds and owns every app-wide service. The composition order is
/// encoded as the order of property assignments in `make(...)` — each
/// row depends only on rows above it, so the dependency graph is
/// readable top-to-bottom without grep.
///
/// Container construction can fail on bad SwiftData migrations, so it
/// returns errors structurally instead of `fatalError`-ing mid-init.
/// Tests can build an alternate container with in-memory stores and
/// stub iCloud via `build(...)`.
@MainActor
struct AppContainer {

    // MARK: - Inputs

    /// UserDefaults flag controlling CloudKit sync. Read at launch and
    /// captured into the container; live toggling requires an app
    /// restart because `ModelContainer` is built once per process.
    static let cloudSyncPreferenceKey = "BuboCloudSyncEnabled"

    static let eventCacheStoreURL: URL = URL.applicationSupportDirectory
        .appending(path: "EventCache.store")
    static let userEventsStoreURL: URL = URL.applicationSupportDirectory
        .appending(path: "UserEvents.store")
    static let backlogStoreURL: URL = URL.applicationSupportDirectory
        .appending(path: "Backlog.store")

    // MARK: - Outputs (the wired-up app graph)

    let settings: ReminderSettings
    let networkMonitor: NetworkMonitor
    let agentService: AgentService
    let cloudServices: CloudServicesCoordinator
    let reminderService: ReminderService
    let backlogService: BacklogService
    let optimizerService: OptimizerService
    let remindersSyncService: RemindersSyncService

    // MARK: - Construction

    /// Build the full app graph for production. Reads the cloud-sync
    /// preference, opens three resilient SwiftData containers backed by
    /// real `.store` files, starts iCloud transports when opted in, and
    /// delegates to `build(...)` for the pure wiring step. Called once
    /// from `BuboApp.init`.
    static func make() -> AppContainer {
        let startedAt = Date()
        let defaults = UserDefaults.standard
        let cloudPreference = defaults.object(forKey: cloudSyncPreferenceKey) as? Bool ?? false

        logger.info("container_build_started cloud_enabled=\(cloudPreference)")

        let eventCacheContainer = resilientContainer(
            storeURL: eventCacheStoreURL,
            cloudEnabled: false
        ) { _ in try makeEventCacheContainer() }

        let userEventsContainer = resilientContainer(
            storeURL: userEventsStoreURL,
            cloudEnabled: cloudPreference
        ) { try makeUserEventsContainer(cloudEnabled: $0) }

        let backlogContainer = resilientContainer(
            storeURL: backlogStoreURL,
            cloudEnabled: cloudPreference
        ) { try makeBacklogContainer(cloudEnabled: $0) }

        let cloudServices = CloudServicesCoordinator()
        if cloudPreference {
            cloudServices.start(
                containerIdentifier: "iCloud.\(Bundle.main.bundleIdentifier ?? "")"
            )
        }

        let container = build(
            settings: ReminderSettings.load(),
            eventCacheContainer: eventCacheContainer,
            userEventsContainer: userEventsContainer,
            backlogContainer: backlogContainer,
            cloudServices: cloudServices
        )

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        logger.info("container_build_completed duration_ms=\(durationMs)")

        return container
    }

    /// Pure wiring step: given every leaf dependency, assemble the
    /// service graph. Extracted out of `make()` so integration tests can
    /// feed in-memory `ModelContainer`s, a fake `CloudServicesCoordinator`,
    /// and assert the resulting graph without actually creating `.store`
    /// files on disk.
    ///
    /// Defaults are only provided for the cheap-to-build side services
    /// (`NetworkMonitor`, `AgentService`); anything touching persistence
    /// or iCloud must be injected explicitly so tests can't accidentally
    /// fall through to a real container.
    static func build(
        settings: ReminderSettings,
        eventCacheContainer: ModelContainer,
        userEventsContainer: ModelContainer,
        backlogContainer: ModelContainer,
        cloudServices: CloudServicesCoordinator,
        networkMonitor: NetworkMonitor? = nil,
        agentService: AgentService? = nil
    ) -> AppContainer {
        let networkMonitor = networkMonitor ?? NetworkMonitor()
        let agentService = agentService ?? AgentService()

        let reminderService = ReminderService(
            settings: settings,
            eventCacheContainer: eventCacheContainer,
            userEventsContainer: userEventsContainer
        )

        let backlogService = BacklogService(modelContainer: backlogContainer)

        let optimizerService = OptimizerService()
        optimizerService.optimizer.preferenceLearner.setupCloudSync()
        optimizerService.backlogService = backlogService
        optimizerService.energyCheckInService = EnergyCheckInService()

        let remindersSyncService = RemindersSyncService(
            settings: settings,
            backlogService: backlogService
        )

        return AppContainer(
            settings: settings,
            networkMonitor: networkMonitor,
            agentService: agentService,
            cloudServices: cloudServices,
            reminderService: reminderService,
            backlogService: backlogService,
            optimizerService: optimizerService,
            remindersSyncService: remindersSyncService
        )
    }

    // MARK: - SwiftData Container Builders

    private static func makeEventCacheContainer() throws -> ModelContainer {
        let schema = Schema([PersistedCachedEvent.self])
        let config = ModelConfiguration(
            schema: schema,
            url: eventCacheStoreURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: config)
    }

    private static func makeUserEventsContainer(cloudEnabled: Bool) throws -> ModelContainer {
        let schema = Schema([
            PersistedLocalEvent.self,
            PersistedExcludedOccurrence.self,
            PersistedReminderOverride.self,
            PersistedEventAttributeOverride.self,
        ])
        let config = ModelConfiguration(
            schema: schema,
            url: userEventsStoreURL,
            cloudKitDatabase: cloudEnabled ? .automatic : .none
        )
        return try ModelContainer(for: schema, configurations: config)
    }

    private static func makeBacklogContainer(cloudEnabled: Bool) throws -> ModelContainer {
        let schema = Schema([PersistedBacklogTask.self])
        let config = ModelConfiguration(
            schema: schema,
            url: backlogStoreURL,
            cloudKitDatabase: cloudEnabled ? .automatic : .none
        )
        return try ModelContainer(for: schema, configurations: config)
    }

    /// Build a container, retrying once with CloudKit disabled if the
    /// mirrored build fails, and falling back to a clean local store if
    /// the file itself is corrupt. Centralising this keeps the three
    /// container init sites from repeating the same recovery dance.
    private static func resilientContainer(
        storeURL: URL,
        cloudEnabled: Bool,
        build: (Bool) throws -> ModelContainer
    ) -> ModelContainer {
        do {
            return try build(cloudEnabled)
        } catch {
            logger.warning("Container at \(storeURL.lastPathComponent) failed to build with cloud=\(cloudEnabled): \(error.localizedDescription)")
            if cloudEnabled, let retry = try? build(false) {
                logger.info("Recovered \(storeURL.lastPathComponent) by disabling CloudKit for this session")
                return retry
            }
            logger.error("Resetting \(storeURL.lastPathComponent) — local store appears corrupt")
            try? FileManager.default.removeItem(at: storeURL)
            for suffix in ["-wal", "-shm"] {
                let sidecar = storeURL.deletingPathExtension()
                    .appendingPathExtension(storeURL.pathExtension + suffix)
                try? FileManager.default.removeItem(at: sidecar)
            }
            do {
                return try build(false)
            } catch {
                fatalError("Failed to create ModelContainer at \(storeURL.lastPathComponent) after reset: \(error)")
            }
        }
    }
}
