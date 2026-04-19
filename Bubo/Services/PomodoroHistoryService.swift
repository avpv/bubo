import Foundation

// MARK: - Pomodoro History Entry

/// A single completed (or abandoned) pomodoro session. Compact by design —
/// we keep only what the resolver needs to bias future sessions.
struct PomodoroHistoryEntry: Codable, Hashable, Sendable {
    let startedAt: Date
    let startHour: Int
    let config: PomodoroConfig
    /// Wall-clock minutes the user actually stayed in the session before
    /// leaving / finishing. Compared to `config.totalMinutes` this tells us
    /// whether the chosen shape was too long.
    let actualMinutes: Int
    /// True when the user ran through the whole plan without bailing.
    let completed: Bool
}

// MARK: - Pomodoro History Service

/// Tiny history store that closes the learning loop between `TimerScreenView`
/// and `PomodoroConfigResolver`. Persists in `UserDefaults` (JSON) — the
/// history is cheap, per-device and <1 KB even after a year of daily use,
/// so a full SwiftData model would be overkill.
///
/// Thread-safety: all access is funnelled through `@MainActor` because the
/// consumers (resolver invocation, timer UI) already run there.
@MainActor
final class PomodoroHistoryService {

    // MARK: Storage

    private let defaultsKey = "BuboPomodoroHistory"
    private let maxEntries = 200

    private let defaults: UserDefaults
    private(set) var entries: [PomodoroHistoryEntry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([PomodoroHistoryEntry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
    }

    // MARK: - Mutations

    func record(_ entry: PomodoroHistoryEntry) {
        entries.append(entry)
        // Cap the log — a rolling window is plenty for learning. Oldest goes.
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    // MARK: - Queries

    /// Recently-completed sessions at roughly the same time of day. Used by
    /// the resolver to bias work / break toward what this user actually
    /// finishes. Non-completed sessions are ignored — they're negative
    /// signal, not preference.
    func learnedConfig(
        forHour hour: Int,
        windowHours: Int = 2,
        recencyDays: Int = 30
    ) -> PomodoroConfig? {
        let cutoff = Date().addingTimeInterval(-Double(recencyDays) * 86400)
        let similar = entries.filter {
            $0.completed
                && $0.startedAt >= cutoff
                && abs($0.startHour - hour) <= windowHours
        }
        guard similar.count >= 3 else { return nil }

        let medWork = median(similar.map { $0.config.workMinutes })
        let medBreak = median(similar.map { $0.config.breakMinutes })
        let medRounds = median(similar.map { $0.config.rounds })
        let medLongBreak = median(similar.map { $0.config.longBreakMinutes })
        return PomodoroConfig(
            workMinutes: medWork,
            breakMinutes: medBreak,
            rounds: medRounds,
            longBreakMinutes: medLongBreak
        )
    }

    private func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }
}
