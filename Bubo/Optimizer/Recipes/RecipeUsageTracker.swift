import Foundation

// MARK: - Recipe Usage Tracker

/// Tracks recipe usage history and ranks recipes using the Hacker News ranking algorithm.
///
/// Score formula (from HN):
///   score = points / (T + 2)^gravity
///
/// Where:
///   - points = number of successful executions (accepted scenarios count double)
///   - T = minutes since last execution
///   - gravity = 1.8 (how fast score decays over time)
///
/// Persists to UserDefaults. Top-N recipes are exposed for the "Recently Used" section.
@MainActor
@Observable
final class RecipeUsageTracker {

    private(set) var entries: [String: RecipeUsageEntry] = [:]

    private let persistenceKey = "BuboRecipeUsageHistory"

    // MARK: - HN Algorithm Parameters

    /// Controls how fast old recipes decay. Higher = faster decay.
    private let gravity: Double = 1.8

    // MARK: - Init

    init() {
        load()
    }

    // MARK: - Record Usage

    /// Call when a recipe execution succeeds.
    func recordExecution(recipeId: String) {
        var entry = entries[recipeId] ?? RecipeUsageEntry()
        entry.executionCount += 1
        entry.lastExecutedAt = Date()
        entries[recipeId] = entry
        save()
    }

    /// Call when the user accepts/applies a scenario from this recipe.
    /// Acceptance is worth more points than just executing.
    func recordAcceptance(recipeId: String) {
        var entry = entries[recipeId] ?? RecipeUsageEntry()
        entry.acceptanceCount += 1
        entries[recipeId] = entry
        save()
    }

    // MARK: - HN Ranking

    /// Returns up to `limit` recipe IDs sorted by HN score (highest first).
    func topRecipeIds(limit: Int = 6) -> [String] {
        let now = Date()
        return entries
            .map { (id: $0.key, score: score(for: $0.value, now: now)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.id)
    }

    /// HN score for a single entry.
    ///   score = points / (T + 2)^gravity
    ///   T = minutes since last execution
    private func score(for entry: RecipeUsageEntry, now: Date) -> Double {
        guard let lastUsed = entry.lastExecutedAt else { return 0 }
        let minutesAgo = now.timeIntervalSince(lastUsed) / 60
        let points = Double(entry.executionCount + entry.acceptanceCount)
        let denominator = pow(minutesAgo + 2, gravity)
        return points / denominator
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([String: RecipeUsageEntry].self, from: data)
        else { return }
        entries = decoded
    }
}

// MARK: - Usage Entry

struct RecipeUsageEntry: Codable, Sendable {
    var executionCount: Int = 0
    var acceptanceCount: Int = 0
    var lastExecutedAt: Date?
}
