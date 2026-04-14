import Foundation

// MARK: - Cloud Sync Service

/// Production-hardened iCloud sync via NSUbiquitousKeyValueStore.
///
/// Features:
/// - Schema versioning — refuses data from incompatible newer app versions
/// - Quota monitoring — warns at 800 KB (limit is 1 MB)
/// - Tombstones — deletion propagation across devices with 30-day TTL
/// - Per-type merge strategies (union by ID, union by timestamp, set union, LWW)
/// - Observable sync status for UI feedback
/// - Full error handling for all iCloud KV store change reasons
@Observable
final class CloudSyncService {

    static let shared = CloudSyncService()

    // MARK: - Schema Version

    /// Increment when encoding of ANY synced key changes in a
    /// backward-incompatible way.  Adding optional Codable fields does NOT
    /// require a bump — only renaming, removing, or changing types does.
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

    // MARK: - Constants

    /// All UserDefaults keys mirrored to iCloud.
    static let syncedKeys: Set<String> = [
        "ReminderSettings",
        "BuboBacklogTasks",
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

    static let tombstoneKey = "BuboCloudSyncTombstones"

    /// Tombstone expiry: 30 days.
    private static let tombstoneTTL: TimeInterval = 30 * 86400
    /// Quota soft limit (80 % of 1 MB).
    private static let quotaWarningThreshold = 819_200
    /// NSUbiquitousKeyValueStore hard limit.
    private static let quotaLimit = 1_048_576

    // MARK: - Internal State

    private let cloud = NSUbiquitousKeyValueStore.default

    /// Prevents push-while-merging feedback loops.
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

    /// Call once at app launch, before services load their data from
    /// UserDefaults.  Pulls / merges existing iCloud data so a fresh device
    /// starts with the user's cloud state.
    func performInitialSync() {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            status = .unavailable
            return
        }

        cloud.synchronize()

        // Schema gate — refuse data from a newer, incompatible version.
        let remoteVersion = cloud.object(forKey: Self.schemaVersionKey) as? Int ?? 0
        if remoteVersion > Self.schemaVersion {
            status = .error(
                "Update Bubo to sync with this iCloud data (v\(remoteVersion))"
            )
            return
        }

        isMerging = true
        defer { isMerging = false }

        // Pull tombstones before task merge so deleted IDs are available.
        if cloud.data(forKey: Self.tombstoneKey) != nil {
            mergeTombstones()
        }

        for key in Self.syncedKeys {
            guard cloud.object(forKey: key) != nil else { continue }
            if UserDefaults.standard.object(forKey: key) == nil {
                // Fresh device — pull cloud data verbatim.
                if let value = cloud.object(forKey: key) {
                    UserDefaults.standard.set(value, forKey: key)
                }
            } else {
                // Both sides have data — merge immediately so services see
                // the full picture on first load.
                merge(key: key)
            }
        }

        // Stamp our schema version.
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

    // MARK: - Tombstone API

    /// Record a task deletion so other devices can remove it.
    func recordTombstone(taskId: String) {
        var tombstones = loadTombstones()
        tombstones[taskId] = Date()
        saveTombstones(tombstones)
        guard !isMerging,
              FileManager.default.ubiquityIdentityToken != nil else { return }
        if let data = UserDefaults.standard.data(forKey: Self.tombstoneKey) {
            cloud.set(data, forKey: Self.tombstoneKey)
        }
    }

    /// Current tombstone set (task ID → deletion date).
    func loadTombstones() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: Self.tombstoneKey),
              let map = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return map
    }

    private func saveTombstones(_ tombstones: [String: Date]) {
        let cutoff = Date().addingTimeInterval(-Self.tombstoneTTL)
        let pruned = tombstones.filter { $0.value > cutoff }
        if let data = try? JSONEncoder().encode(pruned) {
            UserDefaults.standard.set(data, forKey: Self.tombstoneKey)
        }
    }

    // MARK: - Receive Remote Changes

    private func didChangeExternally(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
              let changedKeys = userInfo[
                  NSUbiquitousKeyValueStoreChangedKeysKey
              ] as? [String]
        else { return }

        // Handle non-data reasons first.
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
            break  // ServerChange or InitialSyncChange — continue to merge.
        }

        // Schema gate.
        let remoteVersion = cloud.object(forKey: Self.schemaVersionKey) as? Int ?? 0
        if remoteVersion > Self.schemaVersion {
            status = .error(
                "Update Bubo to sync with this iCloud data (v\(remoteVersion))"
            )
            return
        }

        isMerging = true
        defer { isMerging = false }

        // Tombstones first — they affect the backlog merge.
        if changedKeys.contains(Self.tombstoneKey) {
            mergeTombstones()
        }

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

    // MARK: - Merge Dispatcher

    private func merge(key: String) {
        switch key {
        case "BuboBacklogTasks":
            mergeBacklogTasksFromCloud()
        case "BuboEnergyCheckIns":
            mergeEnergyCheckInsFromCloud()
        case "BuboDismissedReminderIds":
            mergeStringArrayFromCloud(key: key)
        default:
            // Last-writer-wins — cloud overwrites local.
            if let value = cloud.object(forKey: key) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }

    private func mergeTombstones() {
        guard let remoteData = cloud.data(forKey: Self.tombstoneKey),
              let remote = try? JSONDecoder().decode(
                  [String: Date].self, from: remoteData
              )
        else { return }

        var local = loadTombstones()
        for (id, date) in remote {
            if let existing = local[id] {
                local[id] = min(existing, date)   // earliest deletion wins
            } else {
                local[id] = date
            }
        }
        saveTombstones(local)
    }

    // MARK: - Backlog Tasks Merge (union by ID + tombstones)

    private func mergeBacklogTasksFromCloud() {
        let key = "BuboBacklogTasks"
        let decoder = JSONDecoder()

        guard let remoteData = cloud.data(forKey: key),
              let remoteTasks = try? decoder.decode(
                  [BacklogTask].self, from: remoteData
              )
        else { return }

        let localData = UserDefaults.standard.data(forKey: key)
        let localTasks = localData.flatMap {
            try? decoder.decode([BacklogTask].self, from: $0)
        } ?? []

        let tombstones = Set(loadTombstones().keys)
        let merged = Self.mergeBacklogTasks(
            local: localTasks,
            remote: remoteTasks,
            tombstones: tombstones
        )

        if let data = try? JSONEncoder().encode(merged) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Pure, deterministic merge — unit-testable without UserDefaults / iCloud.
    ///
    /// Rules:
    /// 1. Tombstoned IDs are excluded from the result.
    /// 2. Tasks present on both sides are resolved by `resolveTaskConflict`.
    /// 3. Local ordering is preserved; remote-only tasks are appended.
    static func mergeBacklogTasks(
        local: [BacklogTask],
        remote: [BacklogTask],
        tombstones: Set<String>
    ) -> [BacklogTask] {
        let remoteByID = Dictionary(
            remote.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )

        var mergedByID: [String: BacklogTask] = [:]
        var orderedIDs: [String] = []

        // Preserve local ordering; resolve conflicts with remote.
        for task in local {
            guard !tombstones.contains(task.id) else { continue }
            if let remoteTask = remoteByID[task.id] {
                mergedByID[task.id] = resolveTaskConflict(
                    local: task, remote: remoteTask
                )
            } else {
                mergedByID[task.id] = task
            }
            orderedIDs.append(task.id)
        }

        // Remote-only tasks go at the end.
        for task in remote where mergedByID[task.id] == nil {
            guard !tombstones.contains(task.id) else { continue }
            mergedByID[task.id] = task
            orderedIDs.append(task.id)
        }

        return orderedIDs.compactMap { mergedByID[$0] }
    }

    /// Pick the winning version of a task present on both devices.
    ///
    /// Priority chain:
    /// 1. `.done` always wins (completion is irreversible).
    /// 2. `.scheduled` beats `.pending` (more progress).
    /// 3. Same status → prefer the one with the latest `modifiedAt`
    ///    (falls back to `completedAt` → `scheduledDate` → `createdAt`).
    static func resolveTaskConflict(
        local: BacklogTask,
        remote: BacklogTask
    ) -> BacklogTask {
        if local.status == .done && remote.status != .done { return local }
        if remote.status == .done && local.status != .done { return remote }

        if local.status == .scheduled && remote.status == .pending { return local }
        if remote.status == .scheduled && local.status == .pending { return remote }

        let localDate = local.modifiedAt
            ?? local.completedAt ?? local.scheduledDate ?? local.createdAt
        let remoteDate = remote.modifiedAt
            ?? remote.completedAt ?? remote.scheduledDate ?? remote.createdAt
        return remoteDate > localDate ? remote : local
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

    /// Rough estimate of total bytes consumed in the iCloud KV store.
    func estimateStorageUsed() -> Int {
        var bytes = 0
        for key in Self.syncedKeys {
            bytes += sizeOfKey(key)
        }
        bytes += sizeOfKey(Self.tombstoneKey)
        bytes += sizeOfKey(Self.schemaVersionKey)
        return bytes
    }

    private func sizeOfKey(_ key: String) -> Int {
        let overhead = key.utf8.count + 16  // key string + plist envelope
        if let data = UserDefaults.standard.data(forKey: key) {
            return data.count + overhead
        }
        if let array = UserDefaults.standard.array(forKey: key),
           let data = try? JSONSerialization.data(withJSONObject: array) {
            return data.count + overhead
        }
        if UserDefaults.standard.object(forKey: key) != nil {
            return 32 + overhead  // scalar value estimate
        }
        return 0
    }
}
