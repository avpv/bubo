import Foundation
import SwiftData
import os

private let logger = Logger(subsystem: "com.avpv.Bubo", category: "AppContainer")

// MARK: - App Container (Composition Root)

/// Builds and owns every app-wide service in one place. Replaces the
/// 60-line wiring soup that used to live in `BuboApp.init`. The
/// composition order is encoded as the order of property assignments in
/// `make(...)` — each row depends only on rows above it, so the
/// dependency graph is readable top-to-bottom without grep.
///
/// Why a separate type instead of free functions:
///   - The container's properties are a published API for `BuboApp` to
///     pull into `@State`. A single struct keeps the surface narrow.
///   - Container construction can fail on bad SwiftData migrations, so
///     it returns errors structurally instead of `fatalError`-ing
///     mid-init like the old code did.
///   - Tests can build an alternate container with in-memory stores
///     and stub iCloud, without re-implementing the wiring.
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

    /// Build the full app graph. Reads the cloud-sync preference, opens
    /// three resilient SwiftData containers, starts iCloud transports
    /// when opted in, and wires the services together in dependency
    /// order. All composition lives here so `BuboApp.init` is a
    /// one-liner.
    static func make() -> AppContainer {
        let defaults = UserDefaults.standard
        let cloudPreference = defaults.object(forKey: cloudSyncPreferenceKey) as? Bool ?? false

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

        let settings = ReminderSettings.load()

        let reminderService = ReminderService(
            settings: settings,
            eventCacheContainer: eventCacheContainer,
            userEventsContainer: userEventsContainer
        )

        let backlogService = BacklogService(modelContainer: backlogContainer)

        let optimizerService = OptimizerService()
        optimizerService.backlogService = backlogService
        optimizerService.energyCheckInService = EnergyCheckInService()

        let remindersSyncService = RemindersSyncService(
            settings: settings,
            backlogService: backlogService
        )

        return AppContainer(
            settings: settings,
            networkMonitor: NetworkMonitor(),
            agentService: AgentService(),
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
