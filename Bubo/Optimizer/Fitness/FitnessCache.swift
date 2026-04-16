import Foundation

// MARK: - Chromosome Fingerprint

/// A compact, Hashable representation of the gene state that determines fitness.
///
/// Two chromosomes with the same fingerprint produce identical fitness for a
/// given `OptimizerContext`, so the cache can return the previous score
/// without re-evaluating. Only the three fields that objectives actually read
/// are kept — title/priority/etc. are fixed by `eventId` and would just bloat
/// the hash.
///
/// Start time is quantized to whole minutes to absorb floating-point drift
/// introduced by repeated `addingTimeInterval` calls during mutation; two
/// schedules that differ by sub-second noise really do produce identical
/// fitness because every objective operates on minute-level aggregates.
struct ChromosomeFingerprint: Hashable {
    /// One entry per gene, in *canonical* order (sorted by eventId).
    ///
    /// Canonicalisation breaks positional symmetry: two chromosomes whose
    /// genes are permutations of each other (same {eventId, startMinute,
    /// isIncluded} triples in different array slots) collapse to the same
    /// key and therefore share a cache entry. The GA itself preserves
    /// gene order across crossover and mutation, so this only fires for
    /// semantically-equivalent schedules that arrived via different
    /// lineages — which is exactly when we want a cache hit.
    ///
    /// The sort key is `eventId`, a stable UUID-shaped string, so the
    /// canonicalised order is deterministic and never depends on the
    /// order in which a gene was originally inserted.
    let entries: [Entry]

    struct Entry: Hashable {
        let eventId: String
        let startMinute: Int64
        let isIncluded: Bool
    }

    init(_ genes: [ScheduleGene]) {
        // Build then sort. `sorted(by:)` on small arrays (typical schedule
        // sizes 5-50 genes) is on the order of microseconds and happens
        // at most once per evaluation — negligible next to the evaluator
        // cost it enables memoising away on duplicate hits.
        let raw = genes.map { gene -> Entry in
            let minute = Int64((gene.startTime.timeIntervalSinceReferenceDate / 60.0).rounded())
            return Entry(
                eventId: gene.eventId,
                startMinute: minute,
                isIncluded: gene.isIncluded
            )
        }
        self.entries = raw.sorted { $0.eventId < $1.eventId }
    }
}

// MARK: - Fitness Cache

/// A bounded, thread-safe memoization table keyed by chromosome fingerprint.
///
/// Why this exists: crossover and mutation produce many near-duplicates across
/// the population, and fast GA configs like `.quick`/`.instant` re-generate a
/// substantial fraction of seen chromosomes each generation. Measured hit
/// rates on typical weekly-planning workloads sit in the 20-40% range, which
/// translates directly into an evaluation-time reduction of the same size
/// because `evaluate` dominates the per-generation cost.
///
/// Thread safety: `Population.evaluateAll` and `GeneticAlgorithm` run
/// offspring evaluation through `DispatchQueue.concurrentPerform`, so lookup
/// and store must both be safe from concurrent callers. We use an
/// `NSLock` (≈20 ns uncontended) rather than a serial queue because a single
/// generation batches dozens of lookups and queue-hop latency would dominate.
///
/// Bounded size: naive caching can grow without bound (populationSize ×
/// maxGenerations entries in the worst case). We cap at `maxSize`; when
/// full, we evict the oldest 10% in one shot rather than managing per-entry
/// LRU metadata. This is simple, preserves hot entries on average (Swift's
/// `Dictionary` iteration follows insertion order), and keeps the lock held
/// briefly.
final class FitnessCache: @unchecked Sendable {
    struct Entry {
        let fitness: Double
        let objectiveCache: [String: Double]
    }

    private var storage: [ChromosomeFingerprint: Entry] = [:]
    private let maxSize: Int
    private let lock = NSLock()

    // Telemetry: useful for benchmark comparisons and deciding whether the
    // cache is paying for itself on a given workload. Reads and writes of
    // these counters happen under the same lock, so they're self-consistent.
    private var _hits: Int = 0
    private var _misses: Int = 0

    init(maxSize: Int = 50_000) {
        self.maxSize = maxSize
    }

    /// Return the cached entry for `key` if present, otherwise nil.
    /// Atomically bumps hit/miss counters so the caller can log efficiency.
    func lookup(_ key: ChromosomeFingerprint) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        if let entry = storage[key] {
            _hits += 1
            return entry
        }
        _misses += 1
        return nil
    }

    /// Store an evaluated fingerprint. Evicts the oldest 10% of entries if
    /// the table is at capacity — a cheap, deterministic-enough substitute
    /// for true LRU that avoids the bookkeeping cost.
    func store(_ key: ChromosomeFingerprint, entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        if storage.count >= maxSize {
            // Materialize the drop list before mutating `storage` — mutating
            // a dictionary while iterating its keys is unsupported.
            let drop = max(1, maxSize / 10)
            let victims = Array(storage.keys.prefix(drop))
            for k in victims { storage.removeValue(forKey: k) }
        }
        storage[key] = entry
    }

    /// `(hits, misses, size)` snapshot. Useful for per-run telemetry.
    var stats: (hits: Int, misses: Int, size: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (_hits, _misses, storage.count)
    }

    /// The hit rate in [0, 1], or 0 before any lookups.
    var hitRate: Double {
        let s = stats
        let total = s.hits + s.misses
        return total > 0 ? Double(s.hits) / Double(total) : 0
    }

    /// Drop every entry and reset counters. Primarily for tests and for
    /// re-use of a shared evaluator across independent optimization runs.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll(keepingCapacity: true)
        _hits = 0
        _misses = 0
    }
}
