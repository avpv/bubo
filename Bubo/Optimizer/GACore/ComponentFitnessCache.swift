import Foundation

// MARK: - Component Fitness Cache
//
// Memoizes per-component objective contributions across GA generations.
// The premise: the conflict graph decomposes the schedule into weakly
// connected components, and a mutation that only touches component A
// can't change the objective contribution of component B. So if we
// hash the gene state of B and look it up, we recover B's score for
// free.
//
// Usage pattern (caller-driven, opt-in):
//
//   let key = ComponentFitnessCache.componentKey(
//       componentId: cid,
//       geneIds: members,
//       geneByEvent: geneLookup
//   )
//   if let score = cache.value(for: key) {
//       totalFitness += score
//   } else {
//       let score = evaluator.evaluate(component: members, ...)
//       cache.store(key, value: score)
//       totalFitness += score
//   }
//
// The cache lives outside the chromosome so multiple chromosomes can
// share component scores within a generation. Bounded LRU keeps memory
// predictable: typical island holds ~50 chromosomes × ~5 components,
// so 1024 slots covers the working set with room for population
// turnover.

/// 64-bit content key for one component's gene state. Computed by
/// hashing the eventId set + the (startTime, duration, isIncluded)
/// triplet of every member gene. Two genes that match on those three
/// fields produce the same component score, so we don't need to hash
/// title/context/energyCost — those are static per event id.
struct ComponentFitnessKey: Hashable, Sendable {
    let value: UInt64
}

final class ComponentFitnessCache: @unchecked Sendable {

    // MARK: Storage

    private struct Entry {
        let key: ComponentFitnessKey
        let score: Double
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int

    /// Hit/miss counters for telemetry. Atomicity rides on the same
    /// `lock` that guards `entries`, so no separate synchronization
    /// needed.
    private(set) var hits: Int = 0
    private(set) var misses: Int = 0

    // MARK: Init

    /// `capacity = 1024` covers a 4-island setup with ~50 chromosomes
    /// and ~5 components each (1000 working slots) plus headroom for
    /// generation turnover. Bump for larger populations or more
    /// fragmented schedules.
    init(capacity: Int = 1024) {
        precondition(capacity > 0, "Cache capacity must be positive.")
        self.capacity = capacity
    }

    // MARK: Public API

    /// Lookup a stored score. Returns `nil` on miss; callers should
    /// compute and `store` on miss to keep the cache warm.
    func value(for key: ComponentFitnessKey) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        if let idx = entries.firstIndex(where: { $0.key == key }) {
            // LRU touch: move hit to front.
            let hit = entries.remove(at: idx)
            entries.insert(hit, at: 0)
            hits += 1
            return hit.score
        }
        misses += 1
        return nil
    }

    /// Store a freshly-computed component score under `key`. Evicts
    /// the LRU tail when capacity is exceeded. Idempotent: re-storing
    /// an existing key just refreshes its recency.
    func store(_ key: ComponentFitnessKey, value: Double) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = entries.firstIndex(where: { $0.key == key }) {
            entries.remove(at: idx)
        }
        entries.insert(Entry(key: key, score: value), at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }

    /// Drop everything. Called on graph rebuilds (component layout
    /// changes invalidate every cached score) and at session end.
    func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        hits = 0
        misses = 0
    }

    // MARK: Hit Rate Telemetry

    /// Hit rate over the cache's lifetime, in [0, 1]. Returns 0 when
    /// no lookups have happened yet — callers should treat that as
    /// "cold" rather than "ineffective".
    var hitRate: Double {
        lock.lock()
        defer { lock.unlock() }
        let total = hits + misses
        guard total > 0 else { return 0 }
        return Double(hits) / Double(total)
    }

    // MARK: Key Construction

    /// Build a content key for one component.
    ///
    /// Hashes the (eventId, startTime, duration, isIncluded) tuple of
    /// every gene whose eventId is in `geneIds`. Sorts by eventId so
    /// gene-array ordering is irrelevant — two chromosomes with the
    /// same gene set but different array order still hit the same
    /// cache slot.
    ///
    /// Genes missing from `geneByEvent` are skipped silently; a
    /// dropped optional gene contributes the literal "missing" marker
    /// so a subsequent re-inclusion produces a different key.
    static func componentKey(
        componentId: Int,
        geneIds: [String],
        geneByEvent: [String: ScheduleGene]
    ) -> ComponentFitnessKey {
        var hasher = Hasher()
        hasher.combine(componentId)
        hasher.combine(geneIds.count)
        // Sort defensively — `allComponents()` returns members in id
        // order today, but a future change shouldn't silently break
        // cache identity.
        for id in geneIds.sorted() {
            hasher.combine(id)
            if let gene = geneByEvent[id] {
                hasher.combine(gene.startTime.timeIntervalSinceReferenceDate)
                hasher.combine(gene.duration)
                hasher.combine(gene.isIncluded)
            } else {
                // Distinct marker so "gene absent" != "gene at t=0".
                hasher.combine(Int.min)
            }
        }
        return ComponentFitnessKey(value: UInt64(bitPattern: Int64(hasher.finalize())))
    }
}
