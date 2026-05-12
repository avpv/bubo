import CloudKit
import CoreData
import Foundation
import BuboDomain

// MARK: - CloudKit Sync Monitor

/// Observable façade over `NSPersistentCloudKitContainer` + `CKContainer`
/// status so the UI can show a live "syncing / synced / error" indicator
/// instead of guessing silently.
///
/// Responsibilities:
///   - Track `CKAccountStatus` at launch and on `CKAccountChanged`.
///   - Observe `NSPersistentCloudKitContainer.eventChangedNotification` to
///     surface setup / import / export progress and errors.
///   - Publish `didFinishImport` so services (e.g. `BacklogService`) can
///     reconcile their in-memory state after a remote batch lands.
///
/// Kept separate from `CloudSyncService` because that one only deals with
/// `NSUbiquitousKeyValueStore`; CloudKit-backed SwiftData is a different
/// transport and has its own lifecycle.
@Observable
@MainActor
final class CloudKitSyncMonitor: CloudKitSyncMonitoring {

    static let shared = CloudKitSyncMonitor()

    /// Posted after a successful CloudKit *import* event completes. Services
    /// that hold an in-memory mirror of CloudKit-backed data (e.g. the backlog
    /// tasks array) should reload and reconcile on this signal so remote edits
    /// show up without requiring an app restart.
    static let didFinishImport = Notification.Name("BuboCloudKitDidFinishImport")

    // MARK: - Public State

    /// Nested account-status view, kept internal to the monitor because
    /// no outside code ever pattern-matches on it — only `summary`
    /// surfaces a string rendering, which is the protocol requirement.
    enum AccountStatus: Equatable {
        case unknown
        case available
        case noAccount
        case restricted
        case couldNotDetermine
        case temporarilyUnavailable

        var userFacing: String {
            switch self {
            case .unknown: return "Checking iCloud…"
            case .available: return "iCloud account available"
            case .noAccount: return "Sign in to iCloud to enable sync"
            case .restricted: return "iCloud is restricted by parental controls or profile"
            case .couldNotDetermine: return "Can't reach iCloud right now"
            case .temporarilyUnavailable: return "iCloud temporarily unavailable"
            }
        }

        var isBlocking: Bool {
            switch self {
            case .available, .unknown: return false
            default: return true
            }
        }
    }

    private(set) var accountStatus: AccountStatus = .unknown
    private(set) var phase: CloudKitSyncPhase = .idle
    private(set) var lastSyncDate: Date?
    private(set) var lastError: String?

    /// One-line status for UI.
    var summary: String {
        if let err = lastError { return err }
        switch phase {
        case .setup: return "Preparing iCloud…"
        case .importing: return "Downloading from iCloud…"
        case .exporting: return "Uploading to iCloud…"
        case .idle:
            if accountStatus == .available, let last = lastSyncDate {
                let rel = Self.relativeFormatter.localizedString(for: last, relativeTo: Date())
                return "Synced \(rel)"
            }
            return accountStatus.userFacing
        }
    }

    // MARK: - Internals

    /// `nonisolated(unsafe)` mirrors the pattern used by `RemindersSyncService`:
    /// the opaque NotificationCenter token is effectively write-once and read
    /// only at teardown, so the actor check is overkill and would prevent
    /// `deinit` from running under strict concurrency.
    private nonisolated(unsafe) var eventObserver: Any?
    private nonisolated(unsafe) var accountObserver: Any?
    private var containerID: String?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private init() {}

    /// Wire up event + account observers and kick off an initial status
    /// refresh. Call once from app startup, after the backlog
    /// `ModelContainer` has been created — the event notification is
    /// posted against `NSPersistentCloudKitContainer` globally, so we
    /// don't need to pass the container reference in.
    func start(containerIdentifier: String? = nil) {
        guard eventObserver == nil else { return }
        self.containerID = containerIdentifier

        eventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleEvent(note)
            }
        }

        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAccountStatus()
            }
        }

        Task { await refreshAccountStatus() }
    }

    deinit {
        if let o = eventObserver { NotificationCenter.default.removeObserver(o) }
        if let o = accountObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Account Status

    private func refreshAccountStatus() async {
        let container: CKContainer
        if let id = containerID {
            container = CKContainer(identifier: id)
        } else {
            container = CKContainer.default()
        }
        do {
            let status = try await container.accountStatus()
            accountStatus = Self.mapAccountStatus(status)
            if accountStatus != .available {
                phase = .idle
            }
        } catch {
            accountStatus = .couldNotDetermine
            lastError = "iCloud status check failed: \(error.localizedDescription)"
        }
    }

    private static func mapAccountStatus(_ status: CKAccountStatus) -> AccountStatus {
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .couldNotDetermine: return .couldNotDetermine
        case .temporarilyUnavailable: return .temporarilyUnavailable
        @unknown default: return .couldNotDetermine
        }
    }

    // MARK: - Event Handling

    private func handleEvent(_ note: Notification) {
        guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event
        else { return }

        if event.endDate == nil {
            // In-flight.
            phase = Self.mapPhase(event.type)
            return
        }

        // Completed. Clear the in-flight phase and record result.
        phase = .idle
        if event.succeeded {
            lastError = nil
            lastSyncDate = event.endDate
            if event.type == .import {
                NotificationCenter.default.post(name: Self.didFinishImport, object: nil)
            }
        } else if let err = event.error {
            lastError = "iCloud sync error: \(err.localizedDescription)"
        }
    }

    private static func mapPhase(_ type: NSPersistentCloudKitContainer.EventType) -> CloudKitSyncPhase {
        switch type {
        case .setup: return .setup
        case .import: return .importing
        case .export: return .exporting
        @unknown default: return .idle
        }
    }
}
