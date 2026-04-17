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
final class CloudSyncService: CloudKeyValueSyncing {

    static let shared = CloudSyncService()

    // MARK: - Schema Version

    /// Increment when encoding of any synced key changes incompatibly.
    static let schemaVersion = 1
    private static let schemaVersionKey = "BuboSyncSchemaVersion"

    // MARK: - Observable State

    private(set) var status: CloudKeyValueSyncStatus = .idle
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

    /// Hard threshold that triggers proactive cleanup of the keys we know
    /// how to prune (energy check-ins, dismissed reminder IDs). Smaller
    /// than `quotaWarningThreshold` on purpose — by the time we've hit the
    /// warning, iCloud is rejecting writes.
    private static let cleanupThreshold = 716_800  // ~70 %

    /// Maximum number of dismissed reminder IDs we're willing to keep in
    /// the cloud KV store. Each UUID is ~36 bytes plus plist overhead,
    /// so 2000 ≈ 80 KB — well inside quota even with a few hundred
    /// other settings hanging off the same bucket.
    static let maxDismissedReminderIds = 2000

    /// Stricter retention when we're close to quota. Normal retention is
    /// 90 days (see `mergeEnergyCheckIns`).
    private static let emergencyEnergyRetentionDays: Double = 45

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

        performCleanupIfNeeded()
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

        performCleanupIfNeeded()
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
        // If the cap bit, push the trimmed set back so remote converges too.
        if merged.count < Set(local).union(Set(remote)).count {
            cloud.set(merged, forKey: key)
        }
    }

    /// Pure merge — testable.
    ///
    /// `BuboDismissedReminderIds` is unbounded by construction (every
    /// ignored reminder leaves a tombstone), so we cap it at
    /// `maxDismissedReminderIds` after the set-union. The cap is applied
    /// deterministically (sorted, then truncated) so every device converges
    /// on the same trimmed set instead of picking a different 2000-subset
    /// each sync.
    static func mergeStringArrays(
        local: [String], remote: [String],
        cap: Int = maxDismissedReminderIds
    ) -> [String] {
        let union = Set(local).union(Set(remote))
        guard union.count > cap else { return Array(union) }
        return Array(union.sorted().prefix(cap))
    }

    // MARK: - Proactive Cleanup

    /// Trim the largest prunable keys when we cross `cleanupThreshold`.
    /// Writes the trimmed values back to both UserDefaults and the cloud
    /// store so the freed quota is actually reclaimed. Returns the number
    /// of bytes freed (0 when no cleanup was needed).
    @discardableResult
    func performCleanupIfNeeded() -> Int {
        let before = estimateStorageUsed()
        guard before > Self.cleanupThreshold else { return 0 }

        // Energy check-ins — drop anything older than the emergency
        // retention window.
        let checkInKey = "BuboEnergyCheckIns"
        if let data = UserDefaults.standard.data(forKey: checkInKey),
           let items = try? JSONDecoder().decode(
               [EnergyCheckInService.CheckIn].self, from: data
           ) {
            let cutoff = Date().addingTimeInterval(
                -Self.emergencyEnergyRetentionDays * 86400
            )
            let trimmed = items.filter { $0.timestamp >= cutoff }
            if trimmed.count < items.count,
               let newData = try? JSONEncoder().encode(trimmed) {
                UserDefaults.standard.set(newData, forKey: checkInKey)
                if FileManager.default.ubiquityIdentityToken != nil {
                    cloud.set(newData, forKey: checkInKey)
                }
            }
        }

        // Dismissed reminder IDs — enforce the hard cap.
        let dismissedKey = "BuboDismissedReminderIds"
        if let ids = UserDefaults.standard.stringArray(forKey: dismissedKey),
           ids.count > Self.maxDismissedReminderIds {
            let trimmed = Array(ids.sorted().prefix(Self.maxDismissedReminderIds))
            UserDefaults.standard.set(trimmed, forKey: dismissedKey)
            if FileManager.default.ubiquityIdentityToken != nil {
                cloud.set(trimmed, forKey: dismissedKey)
            }
        }

        let after = estimateStorageUsed()
        estimatedStorageBytes = after
        return max(0, before - after)
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
