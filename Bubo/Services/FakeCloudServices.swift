import Foundation

// MARK: - Fake CloudKit Sync Monitor

/// Test / preview double for `CloudKitSyncMonitoring`. Mutable state so
/// tests can drive the coordinator through every phase / error / idle
/// transition without having to boot `NSPersistentCloudKitContainer`.
///
/// Lives in the app target so SwiftUI previews can also use it — the
/// Settings iCloud section rendered with a fake monitor + fake KV sync
/// shows every state without touching real iCloud.
@MainActor
final class FakeCloudKitSyncMonitor: CloudKitSyncMonitoring {
    var phase: CloudKitSyncPhase
    var lastError: String?
    var summary: String
    private(set) var startInvocations: [String?] = []

    init(
        phase: CloudKitSyncPhase = .idle,
        lastError: String? = nil,
        summary: String = "Idle"
    ) {
        self.phase = phase
        self.lastError = lastError
        self.summary = summary
    }

    func start(containerIdentifier: String?) {
        startInvocations.append(containerIdentifier)
    }
}

// MARK: - Fake Cloud Key-Value Sync

final class FakeCloudKeyValueSync: CloudKeyValueSyncing {
    var status: CloudKeyValueSyncStatus
    private(set) var performInitialSyncCallCount: Int = 0

    init(status: CloudKeyValueSyncStatus = .idle) {
        self.status = status
    }

    func performInitialSync() {
        performInitialSyncCallCount += 1
    }
}
