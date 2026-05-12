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
// Backed by `ShardedLRUCache`, so concurrent fitness evaluators in
// the GA's `concurrentPerform` loop hash into independent shards
// instead of contending on a single global lock.
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
// share component scores within a generation.

/// 64-bit content key for one component's gene state. Computed by
/// hashing the eventId set + the (startTime, duration, isIncluded)
/// triplet of every member gene. Two genes that match on those three
/// fields produce the same component score, so we don't need to hash
/// title/context/energyCost — those are static per event id.
public struct ComponentFitnessKey: Hashable, Sendable {

    public init(value: UInt64) {
        self.value = value
    }

    public let value: UInt64
}

public final class ComponentFitnessCache: Sendable {

    private let cache: ShardedLRUCache<Double>

    /// Time-bucket width for `startTime` discretisation in the cache
    /// key. Two genes whose start times fall into the same bucket
    /// hash identically — without this, floating-point noise from
    /// repair operators (sub-second adjustments around minute
    /// boundaries) would bust the cache despite being functionally
    /// identical at the GA's evaluation granularity.
    ///
    /// Default `60` seconds matches the GA's minimum schedulable
    /// quantum (per `MutationOperator` docs); evaluators that care
    /// about sub-minute precision should construct with a smaller
    /// bucket explicitly.
    public let startTimeBucketSeconds: TimeInterval

    /// `capacity = 1024` covers a 4-island setup with ~50 chromosomes
    /// and ~5 components each (1000 working slots) plus headroom for
    /// generation turnover. Bump for larger populations or more
    /// fragmented schedules.
    public init(capacity: Int = 1024, startTimeBucketSeconds: TimeInterval = 60) {
        self.cache = ShardedLRUCache(capacity: capacity)
        self.startTimeBucketSeconds = max(1, startTimeBucketSeconds)
    }

    // MARK: Public API

    /// Lookup a stored score. Returns `nil` on miss; callers should
    /// compute and `store` on miss to keep the cache warm.
    public func value(for key: ComponentFitnessKey) -> Double? {
        cache.lookup(forKey: key.value)
    }

    /// Store a freshly-computed component score under `key`. Evicts
    /// the LRU tail when capacity is exceeded. Idempotent: re-storing
    /// an existing key just refreshes its recency.
    public func store(_ key: ComponentFitnessKey, value: Double) {
        cache.store(forKey: key.value, value: value)
    }

    /// Drop everything. Called on graph rebuilds (component layout
    /// changes invalidate every cached score) and at session end.
    public func invalidateAll() {
        cache.invalidateAll()
    }

    // MARK: Hit Rate Telemetry

    /// Hit rate over the cache's lifetime, in [0, 1]. Returns 0 when
    /// no lookups have happened yet — callers should treat that as
    /// "cold" rather than "ineffective".
    public var hitRate: Double { cache.hitRate }

    // MARK: Key Construction

    /// Build a content key for one component.
    ///
    /// Hashes the (eventId, bucketed-startTime, duration, isIncluded)
    /// tuple of every gene whose eventId is in `geneIds`.
    ///
    /// The caller is expected to pass `geneIds` in a deterministic
    /// order — typically whatever `ScheduleConflictGraph.allComponents()`
    /// returns, which is the movable-events-order bucketing that stays
    /// stable for the lifetime of a graph. The key does not sort
    /// defensively: two chromosomes share a cache slot when they share
    /// the same *graph* (which governs the `geneIds` order anyway), and
    /// the cache is invalidated on graph rebuilds. An O(N log N) sort
    /// per component per chromosome evaluation was previously run here
    /// "defensively" and cost 30-100 µs/generation on typical
    /// schedules while protecting against a hypothetical future caller
    /// that doesn't exist today.
    ///
    /// Genes missing from `geneByEvent` contribute a literal "absent"
    /// marker so a subsequent re-inclusion produces a different key.
    public static func componentKey(
        componentId: Int,
        geneIds: [String],
        geneByEvent: [String: ScheduleGene],
        startTimeBucketSeconds: TimeInterval = 60
    ) -> ComponentFitnessKey {
        var hasher = Hasher()
        hasher.combine(componentId)
        hasher.combine(geneIds.count)
        for id in geneIds {
            hasher.combine(id)
            if let gene = geneByEvent[id] {
                // Bucket the start time so floating-point noise from
                // repair operators doesn't bust the cache. Round to
                // the nearest bucket boundary, then hash the integer
                // bucket index — that way 12:00:00.0 and 12:00:00.4
                // collide for the default 60-second bucket.
                let secs = gene.startTime.timeIntervalSinceReferenceDate
                let bucketIndex = Int64((secs / startTimeBucketSeconds).rounded())
                hasher.combine(bucketIndex)
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
