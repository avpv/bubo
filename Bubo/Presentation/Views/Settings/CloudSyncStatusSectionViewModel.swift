import Foundation
import SwiftUI

// MARK: - CloudSyncStatusSection View Model
//
// Extracts the decision logic out of `CloudSyncStatusSection` so the
// view becomes a pure layout. Three responsibilities:
//
//   1. Read + write the `BuboCloudSyncEnabled` UserDefaults flag.
//   2. Snapshot the flag at launch so we can detect a pending toggle
//      and show a "restart required" hint until the app relaunches.
//      `ModelContainer` is built once per process, so the toggle has no
//      effect mid-session and we have to be explicit about that.
//   3. Project the coordinator's aggregated state (`summary`, `isWarning`,
//      `isSyncInProgress`) plus the ReminderService's `lastPersistenceError`
//      through a single VM so the view doesn't wire through two
//      environment objects.
//
// Not `@Observable` — it's a value type that is re-created on every
// `body` render. SwiftUI handles invalidation for us because its inputs
// (`cloudSyncEnabled`, `cloud`, `reminderService`) are already observed
// by the view.

@MainActor
struct CloudSyncStatusSectionViewModel {
    let cloudSyncEnabled: Bool
    let launchTimeCloudSyncEnabled: Bool
    let cloud: CloudServicesCoordinator
    let persistenceError: String?

    /// True when the toggle's current value differs from the snapshot
    /// captured at launch — the user has queued a change that needs a
    /// restart to take effect.
    var isRestartPending: Bool {
        cloudSyncEnabled != launchTimeCloudSyncEnabled
    }

    /// Show a spinner when a CloudKit import / export is in flight.
    var isSyncInProgress: Bool {
        cloud.isRunning && cloud.cloudKit.phase != .idle
    }

    var statusText: String { cloud.summary }
    var statusIsWarning: Bool { cloud.isWarning }

    /// Stable source of truth for the launch-time snapshot so tests and
    /// the view use the same UserDefaults key. Reads once per VM
    /// construction.
    static func launchTimeCloudSyncEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: AppContainer.cloudSyncPreferenceKey)
    }
}
