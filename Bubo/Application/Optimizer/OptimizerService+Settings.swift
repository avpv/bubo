import Foundation
import BuboOptimizer

// MARK: - Optimizer Settings (persisted)
//
// User-tunable knobs the service mirrors to UserDefaults plus the
// CloudKit-driven cross-device sync. Stored properties for these
// settings live on the main class (extensions cannot add stored
// properties); this file owns the computed views, the working-days
// bridge to the optimizer, and the CloudKit sync wiring.

extension OptimizerService {

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

    var minSlotMinutes: Int {
        FreeSlotFinder.defaultMinSlotMinutes
    }

    func setupCloudSync() {
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

    func handleCloudSync(key: String) {
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
