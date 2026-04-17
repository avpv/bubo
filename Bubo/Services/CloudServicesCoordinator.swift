import CloudKit
import Foundation
import SwiftData

// MARK: - Cloud Services Coordinator

/// Single entry point for everything iCloud-adjacent. Unifies the two
/// independent transports Bubo uses — `NSPersistentCloudKitContainer`
/// (SwiftData mirroring for backlog / user events) and
/// `NSUbiquitousKeyValueStore` (settings + learning data) — behind one
/// facade so the rest of the app stops juggling two separate services
/// and wondering which one to start where.
///
/// Responsibilities:
///   - Start both transports atomically when the user flips the sync
///     toggle (before this, `App.init` had to know to call both).
///   - Expose a single `summary` string for the Settings UI so it stops
///     reasoning about four different status enums.
///   - Republish the underlying services as children so views that need
///     fine-grained state (progress spinner, quota warning) can still
///     read the original types directly.
///
/// This is a lightweight coordinator, not a re-implementation — it owns
/// no state of its own. The authoritative state still lives in
/// `CloudKitSyncMonitor` and `CloudSyncService`; this type just gives
/// the app a single thing to inject and observe.
@Observable
@MainActor
final class CloudServicesCoordinator {

    let cloudKit: CloudKitSyncMonitor
    let keyValue: CloudSyncService

    /// `true` once `start()` has been called successfully. Used by the UI
    /// to distinguish "sync disabled" from "sync enabled but idle".
    private(set) var isRunning: Bool = false

    init(
        cloudKit: CloudKitSyncMonitor = .shared,
        keyValue: CloudSyncService = .shared
    ) {
        self.cloudKit = cloudKit
        self.keyValue = keyValue
    }

    /// Start both transports. Safe to call multiple times — the
    /// underlying services are idempotent.
    func start(containerIdentifier: String) {
        cloudKit.start(containerIdentifier: containerIdentifier)
        keyValue.performInitialSync()
        isRunning = true
    }

    // MARK: - Aggregated Status

    /// One-line summary for the Settings "iCloud Sync" row. Picks the
    /// most interesting state across both transports — error beats
    /// progress beats idle — so the user sees the signal that actually
    /// matters without reading two separate rows.
    var summary: String {
        if !isRunning { return "Disabled" }

        if let err = cloudKit.lastError { return err }
        if case .error(let msg) = keyValue.status { return msg }

        if cloudKit.phase != .idle { return cloudKit.summary }

        switch keyValue.status {
        case .idle: return cloudKit.summary
        case .synced: return cloudKit.summary
        case .quotaWarning(let bytes):
            let kb = bytes / 1024
            return "KV approaching quota (\(kb) KB / 1024 KB)"
        case .unavailable: return "Not signed in to iCloud"
        case .error(let msg): return msg
        }
    }

    /// Whether the aggregated state should be shown as a warning in UI.
    var isWarning: Bool {
        guard isRunning else { return false }
        if cloudKit.lastError != nil { return true }
        switch keyValue.status {
        case .quotaWarning, .error, .unavailable: return true
        default: return false
        }
    }
}
