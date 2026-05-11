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
        return (
            start: saved.start,
            end: saved.end,
            defaultDuration: saved.defaultDurationMinutes
        )
    }
}
