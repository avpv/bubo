import Foundation
import os

// MARK: - Salsa-style IntentGraph cache
//
// Wraps `QueryDB` to give `IntentGraph.build` *fine-grained
// invalidation*: a single intent edit only invalidates the queries
// that touched it, not the entire cache.
//
// Decomposition:
//   * `compile(intent)` — per-intent metadata (phase, deps,
//     suggestions). Dep: `{input(intent)}`. A chip edit on intent X
//     invalidates only X's compile entry; every other intent's
//     compile stays warm.
//   * `conflictPair(a, b)` — boolean-plus-reason for one unordered
//     pair. Dep: `{input(a), input(b)}`. A chip edit on X invalidates
//     at most N pair entries (the ones involving X); the other
//     N·(N-1)/2 - N pair entries stay cached. This is the headline
//     per-pair win over hash-keyed memoization.
//   * `phaseBucket(phase)` — sorted node list for one pipeline phase,
//     driven by whichever intents currently live in that phase.
//     Grouping is a derived view of `compile`, so its dependency set
//     is the union of the phase members' input keys.
//   * Whole-graph entry — composes the above with a bounded LRU so
//     the cache doesn't grow without bound across a long session.
//
// The graph itself is assembled via
// `IntentGraph.build(from:conflictOracle:)`; the oracle reads
// through the per-pair cache so the build's pairwise sweep hits the
// cache instead of re-running `conflictReason` switches.

/// Per-intent compile artifact cached by `IntentGraphSalsaCache`.
/// Pure function of the intent itself — no dependency on other
/// intents in the input list. Caching it lets the Salsa cache reuse
/// it across `graph(for:)` calls with different but overlapping
/// inputs.
struct IntentCompileEntry: Sendable, Hashable {
    let intent: ScheduleIntent
    let nodeId: String
    let phase: IntentGraph.Phase
    let dependencies: [ScheduleIntent]
    let suggestions: [ScheduleIntent]
}

/// Per-pair conflict decision cached by `IntentGraphSalsaCache`.
/// `nil` reason means the pair is compatible; a non-nil string is
/// the human-readable conflict message. `Optional<String>` would do
/// at the type level, but the struct form makes the Hashable /
/// Sendable intent explicit.
struct IntentConflictDecision: Sendable, Hashable {
    let reason: String?
    var hasConflict: Bool { reason != nil }
}

final class IntentGraphSalsaCache: Sendable {

    // MARK: Per-query DBs
    //
    // Swift's generic `QueryDB<Output>` is single-output by design
    // (the cache map's value type is fixed), so one DB per output
    // family.
    private let compileDB: QueryDB<IntentCompileEntry>
    private let conflictDB: QueryDB<IntentConflictDecision>
    private let phaseDB: QueryDB<[IntentCompileEntry]>
    private let graphDB: QueryDB<IntentGraph>

    /// Tracks which intent ids the cache has registered as inputs so
    /// callers don't have to remember which `setInput` calls have
    /// already happened. Guarded by an unfair lock so concurrent
    /// `graph(for:)` calls from parallel SwiftUI re-renders don't
    /// race on the bookkeeping.
    private let registeredInputs: OSAllocatedUnfairLock<Set<String>>

    /// Bounded LRU tracker for whole-graph entries. QueryDB itself
    /// stores unlimited entries; the LRU list drops the oldest
    /// whole-graph query name once the cap is hit so a long session
    /// editing through many intent shapes doesn't grow unbounded.
    private let wholeGraphLRU: OSAllocatedUnfairLock<WholeGraphLRU>

    /// Whole-graph hit/miss counters. A hit means the outer
    /// `graphDB.query(...)` closure did *not* run — the prior entry
    /// was still valid. Misses include both cold-start and
    /// invalidation-driven rebuilds. Emitted as deltas by
    /// `BuboOptimizer.optimize()` to show cache effectiveness per
    /// run without leaking per-call logging overhead into the hot
    /// path.
    private let stats: OSAllocatedUnfairLock<Stats>

    /// Snapshot of the cumulative hit/miss counters. Subtract two
    /// snapshots around a section of work to measure that section's
    /// cache effectiveness in isolation.
    struct Stats: Sendable {
        var hits: Int = 0
        var misses: Int = 0
    }

    private struct WholeGraphLRU: Sendable {
        /// Cached query names in MRU-first order.
        var recencyOrder: [QueryKey] = []
    }

    /// Cap on distinct whole-graph entries retained simultaneously.
    /// Per-intent compile/phase/pair entries aren't capped — they're
    /// bounded by intent diversity (≤ hundreds in practice) and
    /// reusing them is the whole point.
    let wholeGraphCapacity: Int

    init(wholeGraphCapacity: Int = 16) {
        precondition(wholeGraphCapacity > 0, "Capacity must be positive")
        self.wholeGraphCapacity = wholeGraphCapacity
        self.compileDB = QueryDB<IntentCompileEntry>()
        self.conflictDB = QueryDB<IntentConflictDecision>()
        self.phaseDB = QueryDB<[IntentCompileEntry]>()
        self.graphDB = QueryDB<IntentGraph>()
        self.registeredInputs = OSAllocatedUnfairLock(initialState: [])
        self.wholeGraphLRU = OSAllocatedUnfairLock(initialState: WholeGraphLRU())
        self.stats = OSAllocatedUnfairLock(initialState: Stats())
    }

    // MARK: Public API

    /// Build the graph for `intents`, hitting the per-intent compile,
    /// per-pair conflict, and whole-graph caches where possible.
    func graph(for intents: [ScheduleIntent]) -> IntentGraph {
        // Register each intent as an input. First-time keys start at
        // revision 1; already-registered keys have their revision
        // left alone so their cached queries stay valid.
        let intentKeys = intents.map { Self.compileKey(for: $0) }
        registerNewInputs(intentKeys)

        // Register any *additional* input keys that come from
        // auto-resolved dependencies so the conflict oracle can
        // track them too. Dependencies are pure functions of the
        // source intent, so registering them here (without bumping
        // revision) is a safe pre-warm.
        let dependencyIntents = intents.flatMap { IntentGraph.dependencies(for: $0) }
        registerNewInputs(dependencyIntents.map { Self.compileKey(for: $0) })

        // Build through the whole-graph QueryDB. The closure walks
        // each intent's `compile` query (touches per-intent inputs)
        // and uses a conflict oracle that routes through
        // `conflictDB`. Both participate in the QueryDB dependency
        // graph, so a single-intent edit invalidates exactly the
        // queries that touched it.
        let graphKey = QueryKey("intentGraph.whole", Self.shapeFingerprint(intents))
        touchWholeGraphLRU(graphKey)
        // Miss-detection pattern: the `graphDB.query` closure only
        // runs when the entry is stale or absent. Flipping a flag
        // inside the closure captures hit vs miss without changing
        // QueryDB's public shape.
        let missFlag = OSAllocatedUnfairLock(initialState: false)
        let result = graphDB.query(graphKey) { tracker in
            missFlag.withLock { $0 = true }
            // Force every per-intent compile to resolve (this also
            // registers the tracker.read for each input key).
            for intent in intents {
                _ = self.compile(intent, tracker: tracker)
            }

            // Conflict oracle: closure that reads through the
            // per-pair cache. The oracle's signature matches
            // `IntentGraph.conflictReason(_:_:)` exactly.
            let oracle: (ScheduleIntent, ScheduleIntent) -> String? = { a, b in
                let decision = self.conflictPair(a, b, tracker: tracker)
                return decision.reason
            }
            return IntentGraph.build(from: intents, conflictOracle: oracle)
        }
        let wasMiss = missFlag.withLock { $0 }
        stats.withLock { s in
            if wasMiss { s.misses += 1 } else { s.hits += 1 }
        }
        return result
    }

    /// Snapshot of cumulative hit/miss counters. Callers capture one
    /// before a run, one after, and diff them to log per-run cache
    /// effectiveness.
    var statsSnapshot: Stats {
        stats.withLock { $0 }
    }

    /// Materialise the phase bucket for `phase` over `intents`, with
    /// the sorted node list cached per (phase, input shape). Useful
    /// for UI code that re-renders one phase at a time and doesn't
    /// want to rebuild the whole graph.
    func phaseBucket(_ phase: IntentGraph.Phase, in intents: [ScheduleIntent]) -> [IntentCompileEntry] {
        let intentKeys = intents.map { Self.compileKey(for: $0) }
        registerNewInputs(intentKeys)
        let queryName = QueryKey(
            "intentGraph.phase.\(phase.rawValue)",
            Self.shapeFingerprint(intents)
        )
        return phaseDB.query(queryName) { tracker in
            var entries: [IntentCompileEntry] = []
            for intent in intents {
                let entry = self.compile(intent, tracker: tracker)
                if entry.phase == phase {
                    entries.append(entry)
                }
            }
            return entries.sorted { $0.nodeId < $1.nodeId }
        }
    }

    /// Drop everything in the cache. Called from app-level lifecycle
    /// hooks (sign-out, calendar disconnect).
    func invalidateAll() {
        compileDB.invalidateAll()
        conflictDB.invalidateAll()
        phaseDB.invalidateAll()
        graphDB.invalidateAll()
        registeredInputs.withLock { $0.removeAll() }
        wholeGraphLRU.withLock { $0.recencyOrder.removeAll() }
    }

    // MARK: Telemetry

    /// Number of cached whole-graph entries. Surfaced for tests and
    /// the LRU cap enforcement.
    var cachedGraphCount: Int { graphDB.cachedCount }

    /// Number of cached per-pair conflict decisions. A good proxy
    /// for fine-grained reuse: two calls on overlapping intent sets
    /// share most of this count.
    var cachedConflictPairCount: Int { conflictDB.cachedCount }

    /// Number of cached per-intent compile entries. Bounded by the
    /// number of distinct intent payloads seen across the cache's
    /// lifetime.
    var cachedCompileCount: Int { compileDB.cachedCount }

    // MARK: - Internals

    /// Per-intent compile query. Pure function of the intent only —
    /// the closure reads the intent's input key and computes the
    /// derived metadata. Cached entries stay valid across whole-
    /// graph queries that share the intent.
    private func compile(_ intent: ScheduleIntent, tracker: QueryTracker) -> IntentCompileEntry {
        let key = Self.compileKey(for: intent)
        let queryName = QueryKey("intentGraph.compile", Self.canonicalNodeId(for: intent))
        // Track that the outer query depends on this intent's input.
        tracker.read(key)
        return compileDB.query(queryName) { innerTracker in
            innerTracker.read(key)
            return IntentCompileEntry(
                intent: intent,
                nodeId: Self.canonicalNodeId(for: intent),
                phase: IntentGraph.phase(for: intent),
                dependencies: IntentGraph.dependencies(for: intent),
                suggestions: IntentGraph.suggestions(for: intent)
            )
        }
    }

    /// Per-pair conflict query. Reads both intents' input keys via
    /// the tracker so changing either intent invalidates this one
    /// pair (and only this pair — other pair entries that don't
    /// involve the edited intent stay cached).
    ///
    /// Pair ordering is canonicalised by canonical node id so
    /// `(a, b)` and `(b, a)` hit the same cache slot — conflict
    /// reasons are symmetric per `IntentGraph.conflictReason`
    /// semantics.
    private func conflictPair(
        _ a: ScheduleIntent,
        _ b: ScheduleIntent,
        tracker: QueryTracker
    ) -> IntentConflictDecision {
        let idA = Self.canonicalNodeId(for: a)
        let idB = Self.canonicalNodeId(for: b)
        // Canonical order: lexicographic on id.
        let first: ScheduleIntent
        let firstId: String
        let second: ScheduleIntent
        let secondId: String
        if idA <= idB {
            first = a; firstId = idA
            second = b; secondId = idB
        } else {
            first = b; firstId = idB
            second = a; secondId = idA
        }

        let keyA = Self.compileKey(for: first)
        let keyB = Self.compileKey(for: second)
        tracker.read(keyA)
        tracker.read(keyB)

        let queryName = QueryKey("intentGraph.conflict", "\(firstId)|\(secondId)")
        return conflictDB.query(queryName) { innerTracker in
            innerTracker.read(keyA)
            innerTracker.read(keyB)
            return IntentConflictDecision(
                reason: IntentGraph.conflictReason(first, second)
            )
        }
    }

    /// Register newly-seen input keys with every underlying QueryDB.
    /// Already-registered keys are skipped so we don't bump revision
    /// for inputs that haven't actually changed.
    private func registerNewInputs(_ keys: [QueryKey]) {
        registeredInputs.withLock { state in
            for key in keys {
                if state.insert(key.identifier).inserted {
                    self.compileDB.setInput(key)
                    self.conflictDB.setInput(key)
                    self.phaseDB.setInput(key)
                    self.graphDB.setInput(key)
                }
            }
        }
    }

    /// Mark `key` as most-recently-used and evict the oldest
    /// whole-graph entry if we're over the cap. Eviction uses
    /// `invalidateQuery` which removes the cached entry without
    /// bumping any input revisions, so per-intent compile/conflict
    /// entries survive the whole-graph eviction and stay warm for
    /// the next call.
    private func touchWholeGraphLRU(_ key: QueryKey) {
        wholeGraphLRU.withLock { state in
            if let idx = state.recencyOrder.firstIndex(of: key) {
                state.recencyOrder.remove(at: idx)
            }
            state.recencyOrder.insert(key, at: 0)
            while state.recencyOrder.count > self.wholeGraphCapacity {
                let evicted = state.recencyOrder.removeLast()
                self.graphDB.invalidateQuery(evicted)
            }
        }
    }

    // MARK: - Key derivation

    /// QueryKey representing a single intent's input identity.
    /// Domain `intentInput` separates intent inputs from query
    /// names so the two namespaces don't collide.
    private static func compileKey(for intent: ScheduleIntent) -> QueryKey {
        QueryKey("intentInput", canonicalNodeId(for: intent))
    }

    /// Stable string identity for an intent. Derived from
    /// `Hasher.combine(intent)` — `ScheduleIntent` is `Hashable`,
    /// so two intents that compare equal produce the same hash and
    /// thus the same key. Two intents that differ in any payload
    /// (`noEventsBefore(11)` vs `noEventsBefore(14)`) get distinct
    /// keys, which is what cross-call dependency tracking wants:
    /// changing the hour value really is a different input.
    ///
    /// Note this is *finer-grained* than `IntentGraph.nodeId`,
    /// which collapses parameterised variants like
    /// `noEventsBefore(_:)` to a single node id. That collapsing is
    /// the IntentGraph's deduplication policy and applies inside
    /// `build`; the Salsa cache layer above doesn't need to honour
    /// it — coarser node ids would cause false cache hits when the
    /// payload changed.
    private static func canonicalNodeId(for intent: ScheduleIntent) -> String {
        var hasher = Hasher()
        hasher.combine(intent)
        return String(hasher.finalize(), radix: 16)
    }

    /// Whole-graph cache key — stable per *shape* of the input
    /// array. Two `graph(for:)` calls with the same intent set in
    /// the same order share the entry; reordering produces a
    /// different key because dependency resolution is order-aware.
    private static func shapeFingerprint(_ intents: [ScheduleIntent]) -> String {
        var hasher = Hasher()
        hasher.combine(intents.count)
        for intent in intents {
            hasher.combine(canonicalNodeId(for: intent))
        }
        return String(hasher.finalize(), radix: 16)
    }
}
