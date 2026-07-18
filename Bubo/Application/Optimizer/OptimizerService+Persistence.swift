import Foundation

// MARK: - OptimizerService persisted settings
//
// `OptimizerService` carries a small bundle of user-tunable knobs
// (working hours, default task duration) that round-trip through
// UserDefaults — and through CloudKit when sync is enabled. This
// extension owns the encode / decode + UserDefaults bridge; the keys
// (`persistenceKey`, `preferencesKey`) live on the main class so the
// CloudSync subscription can route incoming changes to
// `handleCloudSync(key:)` without crossing this file.

extension OptimizerService {

    fileprivate struct SavedSettings: Codable {
        let start: Int
        let end: Int
        let defaultDurationMinutes: Int
    }

    func saveSettings() {
        guard !isReloadingFromCloud else { return }
        let saved = SavedSettings(
            start: workingHoursStart,
            end: workingHoursEnd,
            defaultDurationMinutes: defaultTaskDurationMinutes
        )
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
            CloudSyncService.shared.push(persistenceKey)
        }
        savePreferences()
    }

    /// Persist just the optimizer preferences blob (the settings-only
    /// `saveSettings()` always also pushes preferences, so they share
    /// this helper). Callers that mutate `optimizer.preferences`
    /// directly use this to round-trip the change without re-serialising
    /// the working-hours settings.
    func savePreferences() {
        guard !isReloadingFromCloud else { return }
        if let data = try? JSONEncoder().encode(optimizer.preferences) {
            UserDefaults.standard.set(data, forKey: preferencesKey)
            CloudSyncService.shared.push(preferencesKey)
        }
    }

    static func loadSettings() -> (start: Int, end: Int, defaultDuration: Int) {
        guard let data = UserDefaults.standard.data(forKey: "BuboOptimizerServiceSettings"),
              let saved = try? JSONDecoder().decode(SavedSettings.self, from: data) else {
            return (start: 9, end: 18, defaultDuration: 60)
        }
        // Sanitize on the way in — blobs written before the didSet
        // range clamps existed can carry end = 24 or start = −1 (the
        // old push-the-other-bound logic without range limits), and a
        // CloudKit peer on an old build can still write them. `init`
        // assigns without triggering didSet, so this is the only gate.
        let start = max(0, min(22, saved.start))
        var end = max(1, min(23, saved.end))
        if end <= start { end = start + 1 }
        return (
            start: start,
            end: end,
            defaultDuration: saved.defaultDurationMinutes
        )
    }

    // MARK: - Per-day working-hours overrides

    func saveWorkingHoursOverrides() {
        guard !isReloadingFromCloud else { return }
        if let data = try? JSONEncoder().encode(workingHoursOverrides) {
            UserDefaults.standard.set(data, forKey: workingHoursOverridesKey)
            CloudSyncService.shared.push(workingHoursOverridesKey)
        }
    }

    static func loadWorkingHoursOverrides() -> [String: DayWorkingHours] {
        guard let data = UserDefaults.standard.data(forKey: "BuboWorkingHoursDayOverrides"),
              let saved = try? JSONDecoder().decode([String: DayWorkingHours].self, from: data) else {
            return [:]
        }
        // Prune history: an override for a past day can never render
        // again — without this the map accumulates one entry per
        // adjusted day forever. The day-key format sorts lexically.
        let todayKey = dayKey(for: Date())
        return saved.filter { $0.key >= todayKey }
    }
}
