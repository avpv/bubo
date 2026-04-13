import Foundation

// MARK: - Cloud Sync Service

/// Synchronizes selected UserDefaults keys to iCloud via NSUbiquitousKeyValueStore.
/// Enables multi-device sync without a custom server — uses Apple's iCloud KV infrastructure.
///
/// Merge strategies per key:
///   - BacklogTasks: union merge by task ID (preserves tasks from all devices)
///   - EnergyCheckIns: union merge by timestamp (combines readings)
///   - DismissedReminderIds: set union (prevents re-import across devices)
///   - Everything else: last-writer-wins (cloud overwrites local)
final class CloudSyncService {

    static let shared = CloudSyncService()

    /// Posted when remote data arrives for a key. `object` is the key name (String).
    static let didReceiveRemoteChange = Notification.Name("BuboCloudSyncDidReceiveRemoteChange")

    private let cloud = NSUbiquitousKeyValueStore.default

    /// Guard against re-entrant pushes while merging remote data.
    private var isMerging = false

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

    private var observer: Any?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] notification in
            self?.didChangeExternally(notification)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Initial Sync

    /// Call once at app launch, before services load their data from UserDefaults.
    /// Pulls any existing iCloud data into empty local keys so a fresh device
    /// starts with the user's cloud state.
    func performInitialSync() {
        cloud.synchronize()

        for key in Self.syncedKeys {
            guard cloud.object(forKey: key) != nil else { continue }
            if UserDefaults.standard.object(forKey: key) == nil {
                // First launch on this device — pull cloud data
                if let value = cloud.object(forKey: key) {
                    UserDefaults.standard.set(value, forKey: key)
                }
            }
            // When both exist the ongoing didChangeExternally handler merges later.
        }
    }

    // MARK: - Push (local -> cloud)

    /// Mirror a UserDefaults key to iCloud. Call after every local save.
    func push(_ key: String) {
        guard Self.syncedKeys.contains(key), !isMerging else { return }
        let value = UserDefaults.standard.object(forKey: key)
        cloud.set(value, forKey: key)
    }

    // MARK: - Receive Remote Changes

    private func didChangeExternally(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let _ = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
              let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        else { return }

        isMerging = true
        defer { isMerging = false }

        for key in changedKeys where Self.syncedKeys.contains(key) {
            merge(key: key)

            NotificationCenter.default.post(
                name: Self.didReceiveRemoteChange,
                object: key
            )
        }
    }

    // MARK: - Merge Strategies

    private func merge(key: String) {
        switch key {
        case "BuboBacklogTasks":
            mergeBacklogTasks()
        case "BuboEnergyCheckIns":
            mergeEnergyCheckIns()
        case "BuboDismissedReminderIds":
            mergeStringArrayUnion(key: key)
        default:
            // Last-writer-wins: cloud overwrites local
            if let value = cloud.object(forKey: key) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }

    // MARK: - Backlog Tasks Merge (union by ID)

    private func mergeBacklogTasks() {
        let key = "BuboBacklogTasks"
        let decoder = JSONDecoder()

        guard let remoteData = cloud.data(forKey: key),
              let remoteTasks = try? decoder.decode([BacklogTask].self, from: remoteData)
        else { return }

        let localData = UserDefaults.standard.data(forKey: key)
        let localTasks = localData.flatMap {
            try? decoder.decode([BacklogTask].self, from: $0)
        } ?? []

        let remoteByID = Dictionary(
            remoteTasks.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )

        var mergedByID: [String: BacklogTask] = [:]
        var orderedIDs: [String] = []

        // Keep local ordering, resolve conflicts per task
        for task in localTasks {
            let resolved: BacklogTask
            if let remote = remoteByID[task.id] {
                resolved = Self.resolveTaskConflict(local: task, remote: remote)
            } else {
                resolved = task
            }
            mergedByID[resolved.id] = resolved
            orderedIDs.append(resolved.id)
        }

        // Append remote-only tasks at the end
        for task in remoteTasks where mergedByID[task.id] == nil {
            mergedByID[task.id] = task
            orderedIDs.append(task.id)
        }

        let merged = orderedIDs.compactMap { mergedByID[$0] }

        if let data = try? JSONEncoder().encode(merged) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Pick the "winning" version of a task that exists on both devices.
    static func resolveTaskConflict(local: BacklogTask, remote: BacklogTask) -> BacklogTask {
        // Completion is terminal — done always wins
        if local.status == .done && remote.status != .done { return local }
        if remote.status == .done && local.status != .done { return remote }

        // Scheduled beats pending (more progress)
        if local.status == .scheduled && remote.status == .pending { return local }
        if remote.status == .scheduled && local.status == .pending { return remote }

        // Same status — take the one with the latest relevant timestamp
        let localDate = local.completedAt ?? local.scheduledDate ?? local.createdAt
        let remoteDate = remote.completedAt ?? remote.scheduledDate ?? remote.createdAt
        return remoteDate > localDate ? remote : local
    }

    // MARK: - Energy Check-Ins Merge (union by timestamp)

    private func mergeEnergyCheckIns() {
        let key = "BuboEnergyCheckIns"
        let decoder = JSONDecoder()

        guard let remoteData = cloud.data(forKey: key),
              let remoteCheckIns = try? decoder.decode(
                  [EnergyCheckInService.CheckIn].self, from: remoteData
              )
        else { return }

        let localData = UserDefaults.standard.data(forKey: key)
        let localCheckIns = localData.flatMap {
            try? decoder.decode([EnergyCheckInService.CheckIn].self, from: $0)
        } ?? []

        // Dedup by rounded timestamp (1-second tolerance)
        var merged = localCheckIns
        let localTimestamps = Set(
            localCheckIns.map { Int($0.timestamp.timeIntervalSinceReferenceDate.rounded()) }
        )

        for remote in remoteCheckIns {
            let ts = Int(remote.timestamp.timeIntervalSinceReferenceDate.rounded())
            if !localTimestamps.contains(ts) {
                merged.append(remote)
            }
        }

        // Retain 90 days, chronological order
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        merged = merged.filter { $0.timestamp >= cutoff }
        merged.sort { $0.timestamp < $1.timestamp }

        if let data = try? JSONEncoder().encode(merged) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - String Array Union

    private func mergeStringArrayUnion(key: String) {
        let remote = cloud.array(forKey: key) as? [String] ?? []
        let local = UserDefaults.standard.stringArray(forKey: key) ?? []
        let merged = Array(Set(local).union(Set(remote)))
        UserDefaults.standard.set(merged, forKey: key)
    }
}
