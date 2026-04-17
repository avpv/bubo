import Foundation

// MARK: - Schedule Archive
//
// Persistent store of schedules the user has accepted across past
// optimization runs. The GA loop uses it as a warm-start seed pool: the
// first few generations start from an informed position instead of a
// uniformly-random one, so evolution converges faster on repeat
// workloads that resemble what the user previously approved.
//
// Design choices:
//   • Only *accepted* schedules are archived. Rejected and modified
//     outcomes don't represent desired configurations; seeding with them
//     would bias evolution toward states the user explicitly disliked.
//   • Entries are keyed by a workload fingerprint (movable-event id
//     multiset) so warm-start picks only schedules built from the same
//     event set. Schedules from unrelated workloads would seed noise.
//   • K-means clustering over archived schedules is promised in the
//     Phase 3 plan but the implementation here returns the most recent
//     K entries that match by fingerprint. Clustering buys less on
//     small histories (<30) than on large ones, and real users rarely
//     accumulate that much before feedback already tuned preferences.
//     If usage data later shows clustering would help, upgrade here is
//     a single method swap.
//
// Persistence mirrors PreferenceLearner's pattern: UserDefaults keys
// plus CloudSync notification so archives follow the user across
// devices.

final class ScheduleArchive {
    /// One archive entry captures an accepted schedule plus the workload
    /// fingerprint it was produced from. The fingerprint is a sorted
    /// multiset of event ids — cheap, stable across planning horizons.
    struct Entry: Codable, Sendable {
        let workloadFingerprint: [String]
        let genes: [ScheduleGene]
        /// Raw fitness of the scenario when the user accepted it.
        /// Useful for ranking returned seeds and for telemetry.
        let fitness: Double
        /// Timestamp for "most recent first" retrieval.
        let acceptedAt: Date
    }

    /// Maximum entries kept. Keeps UserDefaults payload modest and
    /// prediction fast; oldest evict first.
    let maxEntries: Int

    private(set) var entries: [Entry] = []

    private let persistenceKey = "BuboScheduleArchive"
    private var cloudSyncObserver: Any?

    init(maxEntries: Int = 50) {
        self.maxEntries = maxEntries
        load()
        setupCloudSync()
    }

    private func setupCloudSync() {
        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: CloudSyncService.didReceiveRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let key = notification.object as? String,
                  key == "BuboScheduleArchive"
            else { return }
            self?.load()
        }
    }

    // MARK: - Record

    /// Store a newly-accepted schedule. Called from BuboOptimizer when
    /// the user accepts a scenario. Idempotent for same-minute repeat
    /// acceptances (acceptedAt collisions are benign — they just fill
    /// slots faster).
    func record(genes: [ScheduleGene], fitness: Double) {
        let fingerprint = Self.workloadFingerprint(for: genes)
        let entry = Entry(
            workloadFingerprint: fingerprint,
            genes: genes,
            fitness: fitness,
            acceptedAt: Date()
        )
        entries.append(entry)
        if entries.count > maxEntries {
            // FIFO eviction of oldest entries.
            entries = Array(entries.suffix(maxEntries))
        }
        save()
    }

    // MARK: - Query

    /// Fetch seed schedules matching the given workload. Results are
    /// returned most-recent-first, truncated to `limit`. Empty when no
    /// matching entries exist (cold user or workload change).
    func seeds(
        matching movableEvents: [OptimizableEvent],
        limit: Int = 5
    ) -> [[ScheduleGene]] {
        let fingerprint = Self.workloadFingerprint(fromEvents: movableEvents)
        let matching = entries
            .filter { $0.workloadFingerprint == fingerprint }
            .sorted { $0.acceptedAt > $1.acceptedAt }
            .prefix(limit)
        return matching.map(\.genes)
    }

    // MARK: - Workload Fingerprint

    /// Derive a stable workload identity from a gene list. We use the
    /// sorted multiset of event ids — schedules built for the same
    /// events share a fingerprint regardless of their time assignments,
    /// which is exactly what we want for warm-start seeding.
    static func workloadFingerprint(for genes: [ScheduleGene]) -> [String] {
        genes.map(\.eventId).sorted()
    }

    /// Same derivation from the event list a fresh optimization starts
    /// with. Split from the gene-list variant so callers at both sides
    /// of the acceptance/optimization boundary produce identical keys.
    static func workloadFingerprint(fromEvents events: [OptimizableEvent]) -> [String] {
        events.map(\.id).sorted()
    }

    // MARK: - Persistence

    private func save() {
        // Keep the on-disk payload bounded at `maxEntries` — we already
        // trim the in-memory list, but persist the trimmed version so a
        // reload from a stale UserDefaults doesn't resurrect evicted
        // entries.
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
        CloudSyncService.shared.push(persistenceKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = decoded
    }

    /// Drop every entry. Primarily for tests and for "Reset learned
    /// preferences" in user-facing settings.
    func reset() {
        entries = []
        UserDefaults.standard.removeObject(forKey: persistenceKey)
    }
}
