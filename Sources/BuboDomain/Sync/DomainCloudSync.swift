import Foundation

/// Notification names used to bridge the pure-domain BuboDomain layer to
/// the iCloud key-value sync service that lives in the main `Bubo` target.
///
/// BuboDomain can't reference `CloudSyncService` directly without forming
/// an upward dependency, so domain types post / observe these notifications
/// and the service in `Bubo/Infrastructure/Cloud/CloudSyncService.swift`
/// translates them into actual push / merge calls.
public enum DomainCloudSync {
    /// Posted by domain types after they've persisted a synced
    /// UserDefaults key locally. `object` is the key name (`String`).
    /// Observed by `CloudSyncService` to mirror the new value to iCloud.
    public static let shouldPushKey = Notification.Name(
        "BuboDomainShouldPushKey"
    )

    /// Posted by `CloudSyncService` after merging remote data for a key
    /// into local UserDefaults. Domain types observe this to reload
    /// their in-memory state from the freshly-merged storage. `object`
    /// is the key name (`String`).
    ///
    /// String value is kept stable for backward compatibility with
    /// existing `CloudSyncService.didReceiveRemoteChange` observers.
    public static let didReceiveRemoteChange = Notification.Name(
        "BuboCloudSyncDidReceiveRemoteChange"
    )
}
