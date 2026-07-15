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
        case workingHoursOverridesKey:
            workingHoursOverrides = Self.loadWorkingHoursOverrides()
        default:
            break
        }
    }

    var workingHours: ClosedRange<Int> {
        workingHoursStart...workingHoursEnd
    }

    // MARK: - Per-day working hours

    /// Day key for `workingHoursOverrides` («2026-07-15»). Fixed
    /// format: the keys sort chronologically as strings, which the
    /// load-time pruning of past days relies on.
    static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    /// The working hours in force on `date` — the day's override when
    /// the user adjusted that day inline on the timeline, otherwise
    /// the global default from Settings → Optimizer.
    ///
    /// Scope note: per-day overrides currently shape the visible
    /// timeline (free slots, boundary handles, «After hours») and the
    /// today-verdicts (capacity ring, Plan chip forecast). The
    /// GA/intents pipeline still plans with the global default —
    /// threading per-day windows through the compiler is a separate
    /// pass.
    func workingHours(on date: Date) -> ClosedRange<Int> {
        if let day = workingHoursOverrides[Self.dayKey(for: date)] {
            return day.start...day.end
        }
        return workingHours
    }

    /// Adjust ONE day's working hours without touching the global
    /// rule. Passing only `start` or only `end` nudges that bound;
    /// the other keeps the day's current value. Clamps mirror the
    /// global setters (start 0…22, end 1…23, start < end preserved by
    /// pushing the other bound). An override that lands back on the
    /// default is removed — a day that matches the rule needs no entry.
    func setWorkingHours(on date: Date, start: Int? = nil, end: Int? = nil) {
        let current = workingHours(on: date)
        var day = DayWorkingHours(start: current.lowerBound, end: current.upperBound)
        if let start {
            day.start = max(0, min(22, start))
            if day.end <= day.start { day.end = day.start + 1 }
        }
        if let end {
            day.end = max(1, min(23, end))
            if day.start >= day.end { day.start = day.end - 1 }
        }
        let key = Self.dayKey(for: date)
        if day == DayWorkingHours(start: workingHoursStart, end: workingHoursEnd) {
            workingHoursOverrides.removeValue(forKey: key)
        } else {
            workingHoursOverrides[key] = day
        }
    }

}
