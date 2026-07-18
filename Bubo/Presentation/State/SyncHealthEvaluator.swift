import Foundation

// MARK: - Sync Health Evaluator

/// Decides when the menu-bar icon carries the sync-failure mark — the
/// Bubo analog of Apple Calendar's per-account ⚠️ (and Time Machine's
/// «!» over its menu-bar icon when a backup fails). EventKit exposes no
/// per-account sync errors to third-party apps, so the mark reports the
/// failures Bubo can actually observe: its own calendar pipeline and the
/// iCloud transports for Bubo's own data.
///
/// Pure static logic (same rationale as `CloudServicesCoordinator`'s
/// static aggregators): every state combination is testable without
/// spinning up services.
enum SyncHealthEvaluator {

    /// True when the icon should carry the failure mark.
    ///
    /// - Offline gates everything off: no network is an environmental
    ///   condition the Wi-Fi menu already reports, and any sync error
    ///   produced *while* offline is noise until connectivity returns.
    /// - Calendar-side signals only count while calendar sync is
    ///   enabled — a deliberately disabled integration is not a failure.
    /// - `cloudSyncWarning` is `CloudServicesCoordinator.isWarning`,
    ///   already gated on the user having enabled iCloud sync.
    static func menuBarWarning(
        isConnected: Bool,
        calendarSyncEnabled: Bool,
        calendarSyncError: String?,
        calendarSyncStale: Bool,
        cloudSyncWarning: Bool
    ) -> Bool {
        guard isConnected else { return false }
        let calendarBroken = calendarSyncEnabled
            && (calendarSyncError != nil || calendarSyncStale)
        return calendarBroken || cloudSyncWarning
    }
}
