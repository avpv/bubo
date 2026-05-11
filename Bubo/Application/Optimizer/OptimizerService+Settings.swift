import Foundation
import SwiftUI

// MARK: - Optimizer Settings (persisted)
//
// User-tunable knobs the service mirrors to UserDefaults plus the
// CloudKit-driven cross-device sync. Extracted from OptimizerService.swift.

extension OptimizerService {

    // MARK: - Optimizer Settings (persisted)

    var workingHoursStart: Int {
        didSet {
            if workingHoursStart >= workingHoursEnd {
                workingHoursEnd = workingHoursStart + 1
            }
            saveSettings()
        }
    }
    var workingHoursEnd: Int {
        didSet {
            if workingHoursEnd <= workingHoursStart {
                workingHoursStart = workingHoursEnd - 1
            }
            saveSettings()
        }
    }

    /// Working-day picker binding for `OptimizerPreferences.workingDays`.
    /// Lives on the service so every surface that tweaks working time
    /// binds to the same source of truth, and so the setter routes
    /// the change through `savePreferences()` — otherwise a UI change
    /// would be lost on relaunch. Uses Foundation's 1-indexed weekday
    /// convention (1 = Sun, …, 7 = Sat).
    var workingDays: Set<Int> {
        get { optimizer.preferences.workingDays }
        set {
            optimizer.preferences.workingDays = newValue
            savePreferences()
        }
    }

    /// Default duration (in minutes) applied to new backlog tasks when the
    /// user doesn't specify one (no `1h`/`30m` suffix in the title). The
    /// ghost preview and the actual create path share this value via
    /// `BacklogView`. Clamped on assignment to the same 5 min – 12 h window
    /// as `BacklogTitleParser` so the two stay consistent.
    var defaultTaskDurationMinutes: Int {
        didSet {
            let clamped = max(5, min(12 * 60, defaultTaskDurationMinutes))
            if clamped != defaultTaskDurationMinutes {
                defaultTaskDurationMinutes = clamped
                return
            }
            saveSettings()
        }
    }

    var minSlotMinutes: Int {
        FreeSlotFinder.defaultMinSlotMinutes
    }

    // Internal so `OptimizerService+Persistence` (sibling file) can
    // round-trip through UserDefaults under the same keys the CloudKit
    // change observer routes by.
    let persistenceKey = "BuboOptimizerServiceSettings"
    let preferencesKey = "BuboOptimizerPreferences"

    /// Prevents didSet -> save -> push loop when reloading cloud data.
    // Internal so `OptimizerService+Persistence` can short-circuit
    // `saveSettings` during a CloudKit-driven reload to avoid bouncing
    // the change back to the network.
    var isReloadingFromCloud = false
    private var cloudSyncObserver: Any?

    init() {
        let saved = Self.loadSettings()
        self.workingHoursStart = saved.start
        self.workingHoursEnd = saved.end
        self.defaultTaskDurationMinutes = saved.defaultDuration
        // Persisted preferences are tried best-effort — if the on-disk
        // blob predates the current model (e.g. the old `skipWeekends`
        // Bool has been dropped and `workingDays` is now non-optional),
        // decode throws and we fall through to a fresh default preferences
        // instance. First-run after upgrade will reset other preference
        // fields too; that's the explicit "no backward compat" trade.
        if let data = UserDefaults.standard.data(forKey: "BuboOptimizerPreferences"),
           let prefs = try? JSONDecoder().decode(OptimizerPreferences.self, from: data) {
            self.optimizer.preferences = prefs
        }
        setupCloudSync()
    }

    private func setupCloudSync() {
        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: CloudSyncService.didReceiveRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let key = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.handleCloudSync(key: key)
            }
        }
    }

    private func handleCloudSync(key: String) {
        isReloadingFromCloud = true
        defer { isReloadingFromCloud = false }

        switch key {
        case persistenceKey:
            let saved = Self.loadSettings()
            workingHoursStart = saved.start
            workingHoursEnd = saved.end
            defaultTaskDurationMinutes = saved.defaultDuration
        case preferencesKey:
            if let data = UserDefaults.standard.data(forKey: preferencesKey),
               let prefs = try? JSONDecoder().decode(OptimizerPreferences.self, from: data) {
                optimizer.preferences = prefs
            }
        default:
            break
        }
    }

    var workingHours: ClosedRange<Int> {
        workingHoursStart...workingHoursEnd
    }

}
