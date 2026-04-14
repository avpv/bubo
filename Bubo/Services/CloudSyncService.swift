import Foundation

// MARK: - Cloud Sync Service

/// Syncs settings and learning data via NSUbiquitousKeyValueStore (iCloud KV).
///
/// Backlog tasks are NOT handled here — they live in SwiftData with CloudKit
/// sync, which Apple manages automatically.  This service only mirrors small
/// blobs (settings, learned weights, energy check-ins, etc.).
///
/// Merge strategies:
///   - EnergyCheckIns: union by timestamp (combines readings from all devices)
///   - DismissedReminderIds: set union (prevents re-import on any device)
///   - Everything else: last-writer-wins (cloud overwrites local)
@Observable
final class CloudSyncService {

    static let shared = CloudSyncService()

    // MARK: - Schema Version

    /// Increment when encoding of any synced key changes incompatibly.
    static let schemaVersion = 1
    private static let schemaVersionKey = "BuboSyncSchemaVersion"

    // MARK: - Observable State

    enum SyncStatus: Equatable {
        case idle
        case synced(Date)
        case quotaWarning(usedBytes: Int)
        case error(String)
        case unavailable
    }

    private(set) var status: SyncStatus = .idle
    private(set) var lastSyncDate: Date?
    private(set) var estimatedStorageBytes: Int = 0

    // MARK: - Notifications

    /// Posted after remote data for a key is merged into UserDefaults.
    /// `object` is the key name (String).
    static let didReceiveRemoteChange = Notification.Name(
        "BuboCloudSyncDidReceiveRemoteChange"
    )

    // MARK: - Synced Keys (settings & learning data only — NOT tasks)

    static let syncedKeys: Set<String> = [
        "ReminderSettings",
        "BuboOptimizerLearnedWeights",
        "BuboOptimizerFeedbackHistory",
        "BuboEnergyCheckIns",
        "BuboIntentLearnerHistory",
        "BuboIntentLearnerHistory.patterns",
        "BuboIntentLearnerHistory.frequency",
        "BuboOptimizerServiceSettings",
        "BuboOptimizerPreferences",
        "BuboColorContextLabels",
        "BuboSubgraphRegistry",
        "BuboDismissedReminderIds",
    ]

    /// Quota soft limit (80 % of 1 MB).
    private static let quotaWarningThreshold = 819_200

    // MARK: - Internal State

    private let cloud = NSUbiquitousKeyValueStore.default
    private var isMerging = false
    private var changeObserver: Any?
    private var accountObserver: Any?

    // MARK: - Init

    private init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] notification in
            self?.didChangeExternally(notification)
        }

        accountObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAccountChange()
        }

        if FileManager.default.ubiquityIdentityToken == nil {
            status = .unavailable
        }
    }

    deinit {
        if let o = changeObserver { NotificationCenter.default.removeObserver(o) }
        if let o = accountObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Initial Sync

    /// Call once at app launch, before services load their data.
    func performInitialSync() {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            status = .unavailable
            return
        }

        cloud.synchronize()

        let remoteVersion = cloud.object(forKey: Self.schemaVersionKey) as? Int ?? 0
        if remoteVersion > Self.schemaVersion {
            status = .error(
                "Update Bubo to sync with this iCloud data (v\(remoteVersion))"
            )
            return
        }

        isMerging = true
        defer { isMerging = false }

        for key in Self.syncedKeys {
            guard cloud.object(forKey: key) != nil else { continue }
            if UserDefaults.standard.object(forKey: key) == nil {
                if let value = cloud.object(forKey: key) {
                    UserDefaults.standard.set(value, forKey: key)
                }
            } else {
                merge(key: key)
            }
        }

        cloud.set(Self.schemaVersion, forKey: Self.schemaVersionKey)

        estimatedStorageBytes = estimateStorageUsed()
        lastSyncDate = Date()
        status = estimatedStorageBytes > Self.quotaWarningThreshold
            ? .quotaWarning(usedBytes: estimatedStorageBytes)
            : .synced(Date())
    }

    // MARK: - Push (local → cloud)

    /// Mirror a UserDefaults key to iCloud.  Call after every local save.
    func push(_ key: String) {
        guard Self.syncedKeys.contains(key), !isMerging else { return }
        guard FileManager.default.ubiquityIdentityToken != nil else { return }

        cloud.set(Self.schemaVersion, forKey: Self.schemaVersionKey)
        let value = UserDefaults.standard.object(forKey: key)
        cloud.set(value, forKey: key)
    }

    // MARK: - Receive Remote Changes

    private func didChangeExternally(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
              let changedKeys = userInfo[
                  NSUbiquitousKeyValueStoreChangedKeysKey
              ] as? [String]
        else { return }

        switch reason {
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            let used = estimateStorageUsed()
            estimatedStorageBytes = used
            status = .quotaWarning(usedBytes: used)
            return

        case NSUbiquitousKeyValueStoreAccountChange:
            handleAccountChange()
            return

        default:
            break
        }

        let remoteVersion = cloud.object(forKey: Self.schemaVersionKey) as? Int ?? 0
        if remoteVersion > Self.schemaVersion {
            status = .error(
                "Update Bubo to sync with this iCloud data (v\(remoteVersion))"
            )
            return
        }

        isMerging = true
        defer { isMerging = false }

        for key in changedKeys where Self.syncedKeys.contains(key) {
            merge(key: key)
            NotificationCenter.default.post(
                name: Self.didReceiveRemoteChange,
                object: key
            )
        }

        estimatedStorageBytes = estimateStorageUsed()
        lastSyncDate = Date()
        status = estimatedStorageBytes > Self.quotaWarningThreshold
            ? .quotaWarning(usedBytes: estimatedStorageBytes)
            : .synced(Date())
    }

    private func handleAccountChange() {
        if FileManager.default.ubiquityIdentityToken == nil {
            status = .unavailable
        } else {
            performInitialSync()
        }
    }

    // MARK: - Merge Strategies

    private func merge(key: String) {
        switch key {
        case "BuboEnergyCheckIns":
            mergeEnergyCheckInsFromCloud()
        case "BuboDismissedReminderIds":
            mergeStringArrayFromCloud(key: key)
        default:
            // Last-writer-wins.
            if let value = cloud.object(forKey: key) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }

    // MARK: - Energy Check-Ins Merge (union by timestamp)

    private func mergeEnergyCheckInsFromCloud() {
        let key = "BuboEnergyCheckIns"
        let decoder = JSONDecoder()

        guard let remoteData = cloud.data(forKey: key),
              let remoteItems = try? decoder.decode(
                  [EnergyCheckInService.CheckIn].self, from: remoteData
              )
        else { return }

        let localData = UserDefaults.standard.data(forKey: key)
        let localItems = localData.flatMap {
            try? decoder.decode(
                [EnergyCheckInService.CheckIn].self, from: $0
            )
        } ?? []

        let merged = Self.mergeEnergyCheckIns(
            local: localItems, remote: remoteItems
        )

        if let data = try? JSONEncoder().encode(merged) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Pure merge — testable.
    static func mergeEnergyCheckIns(
        local: [EnergyCheckInService.CheckIn],
        remote: [EnergyCheckInService.CheckIn]
    ) -> [EnergyCheckInService.CheckIn] {
        var merged = local
        let localTimestamps = Set(
            local.map {
                Int($0.timestamp.timeIntervalSinceReferenceDate.rounded())
            }
        )

        for item in remote {
            let ts = Int(item.timestamp.timeIntervalSinceReferenceDate.rounded())
            if !localTimestamps.contains(ts) {
                merged.append(item)
            }
        }

        let cutoff = Date().addingTimeInterval(-90 * 86400)
        merged = merged.filter { $0.timestamp >= cutoff }
        merged.sort { $0.timestamp < $1.timestamp }
        return merged
    }

    // MARK: - String Array Merge (set union)

    private func mergeStringArrayFromCloud(key: String) {
        let remote = cloud.array(forKey: key) as? [String] ?? []
        let local = UserDefaults.standard.stringArray(forKey: key) ?? []
        let merged = Self.mergeStringArrays(local: local, remote: remote)
        UserDefaults.standard.set(merged, forKey: key)
    }

    /// Pure merge — testable.
    static func mergeStringArrays(
        local: [String], remote: [String]
    ) -> [String] {
        Array(Set(local).union(Set(remote)))
    }

    // MARK: - Quota Monitoring

    func estimateStorageUsed() -> Int {
        var bytes = 0
        for key in Self.syncedKeys {
            bytes += sizeOfKey(key)
        }
        bytes += sizeOfKey(Self.schemaVersionKey)
        return bytes
    }

    private func sizeOfKey(_ key: String) -> Int {
        let overhead = key.utf8.count + 16
        if let data = UserDefaults.standard.data(forKey: key) {
            return data.count + overhead
        }
        if let array = UserDefaults.standard.array(forKey: key),
           let data = try? JSONSerialization.data(withJSONObject: array) {
            return data.count + overhead
        }
        if UserDefaults.standard.object(forKey: key) != nil {
            return 32 + overhead
        }
        return 0
    }
}
