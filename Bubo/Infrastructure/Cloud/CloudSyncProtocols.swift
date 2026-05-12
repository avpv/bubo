import Foundation
import BuboDomain

// MARK: - Cloud Sync Types
//
// Top-level enums shared between the cloud-sync protocols and their
// concrete implementations. Hoisted out of the implementing classes so
// protocol signatures can mention them without leaking class-internal
// names — required for tests and fakes.

/// In-flight CloudKit transport phase. `idle` means "no batch is
/// currently crossing the wire"; the other three map to the coarse
/// `NSPersistentCloudKitContainer.EventType` values.
enum CloudKitSyncPhase: Equatable {
    case idle
    case setup
    case importing
    case exporting
}

/// Observable state of `NSUbiquitousKeyValueStore` sync. Maps one-to-one
/// onto what the Settings UI wants to render: idle, successful sync,
/// approaching quota, explicit error, or "user isn't signed in".
enum CloudKeyValueSyncStatus: Equatable {
    case idle
    case synced(Date)
    case quotaWarning(usedBytes: Int)
    case error(String)
    case unavailable
}

// MARK: - Protocols

/// Read-only state surface of the CloudKit sync monitor, plus the
/// explicit `start` entry point. Allows `CloudServicesCoordinator` to
/// take the monitor by protocol so tests can drive the coordinator
/// with `FakeCloudKitSyncMonitor`.
///
/// Not `@MainActor` on the protocol because `AnyObject` + property
/// access already matches the concrete `@MainActor` class's isolation
/// in practice (every caller is on the main actor). Marking the protocol
/// explicitly would force non-main-actor mocks into a contortion.
@MainActor
protocol CloudKitSyncMonitoring: AnyObject {
    var phase: CloudKitSyncPhase { get }
    var lastError: String? { get }
    /// One-line human-readable summary — used by the Settings UI.
    /// Implementations fold phase + account status + last error into a
    /// single string.
    var summary: String { get }

    /// Idempotent start. The coordinator may call this multiple times;
    /// concrete implementations no-op if already running.
    func start(containerIdentifier: String?)
}

/// Read-only state surface + the initial-sync trigger for the iCloud
/// key-value store. Same reasoning as `CloudKitSyncMonitoring`.
protocol CloudKeyValueSyncing: AnyObject {
    var status: CloudKeyValueSyncStatus { get }

    /// Kick off the first sync. Call once at app launch after the user
    /// opts into cloud sync. Implementations no-op if iCloud KV is
    /// unavailable (no signed-in Apple ID).
    func performInitialSync()
}
