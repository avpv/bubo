import Foundation
import os

// MARK: - Salsa-style IntentGraph cache
//
// Wraps `QueryDB` to give `IntentGraph.build` *fine-grained
// invalidation*: a single intent edit only invalidates the queries
// that touched it, not the entire cache.
//
// How the dependency tracking works:
//   * Each intent in the input array becomes a `QueryKey` input,
//     keyed by the intent's stable id (`compileKey(for:)`).
//   * Per-intent compile artifacts (phase, dependencies, suggestions,
//     conflict-bucket) are cached as separate queries — so two
//     successive `graph(for:)` calls that share most intents reuse
//     those compile entries even if the whole-graph result rebuilds.
//   * The whole-graph query reads every per-intent compile artifact,
//     so adding/removing one intent only invalidates that intent's
//     compile entry plus the whole-graph query — every other
//     intent's compile artifact stays warm.
//
// Why bother when the existing `IntentGraphCache` (hash-keyed LRU)
// already covers the common "rapid edit, same input" case:
//
//   * Hash-keyed LRU treats every input mutation as a fresh entry.
//     With 8 slots and a user toggling 9+ chips, the cache thrashes.
//   * Salsa-style invalidation reuses unchanged inputs across
//     differently-shaped queries. As we decompose `IntentGraph` into
//     more queries (per-intent dependency closure, per-pair conflict
//     check, per-phase grouping), each gets its own invalidation
//     boundary — a chip toggle invalidates only the slice of queries
//     that touched it.
//
// Today: only the whole-graph query is decomposed enough to show
// per-intent invalidation. The compile-entry queries are O(1) so
// caching them is essentially free; the value comes from the
// scaffolding being in place when the algorithm decomposes further
// (see TODO in `wholeGraph(for:)` for the planned decomposition).

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

final class IntentGraphSalsaCache: Sendable {

    // Two query DBs — one per output type. Swift's generic
    // `QueryDB<Output>` is single-output by design (the cache map's
    // value type is fixed), so two output families = two DBs.
    private let compileDB: QueryDB<IntentCompileEntry>
    private let graphDB: QueryDB<IntentGraph>

    /// Tracks which intent ids the cache has registered as inputs so
    /// callers don't have to remember which `setInput` calls have
    /// already happened. Guarded by an unfair lock so concurrent
    /// `graph(for:)` calls from parallel SwiftUI re-renders don't
    /// race on the bookkeeping.
    private let registeredInputs: OSAllocatedUnfairLock<Set<String>>

    init() {
        self.compileDB = QueryDB<IntentCompileEntry>()
        self.graphDB = QueryDB<IntentGraph>()
        self.registeredInputs = OSAllocatedUnfairLock(initialState: [])
    }

    // MARK: Public API

    /// Build the graph for `intents`, hitting the per-intent compile
    /// cache and whole-graph cache where possible.
    func graph(for intents: [ScheduleIntent]) -> IntentGraph {
        // Register each intent as an input. `setInputs` bumps the
        // revision for any intent whose key is being re-registered;
        // first-time keys start at revision 1. The cumulative effect:
        // intents that were already registered with the same id
        // since the last call see no revision change → their cached
        // queries stay valid. Intents that disappeared since the
        // last call still hold their old revision (the next caller
        // can `forgetInput` to drop them; for now we accept the
        // memory footprint).
        let intentKeys = intents.map { Self.compileKey(for: $0) }
        registerNewInputs(intentKeys)

        // The whole-graph query name encodes the full input set so
        // two different input shapes don't share the slot. Inside,
        // we read every per-intent compile entry, which transitively
        // reads each intent's input key — that's how the QueryDB
        // learns which intents the whole-graph result depends on.
        let graphKey = QueryKey("intentGraph.whole", Self.shapeFingerprint(intents))
        return graphDB.query(graphKey) { tracker in
            var compileEntries: [IntentCompileEntry] = []
            compileEntries.reserveCapacity(intents.count)
            for intent in intents {
                let entry = self.compile(intent, tracker: tracker)
                compileEntries.append(entry)
            }
            // TODO: Decompose further. Today we hand `compileEntries`
            //       straight to `IntentGraph.build(from:)`, which
            //       re-runs auto-resolution + conflict detection
            //       monolithically. Future work splits those into
            //       per-intent queries (`autoDepsFor(intent)`,
            //       `conflictsBetween(a, b)`) so a single intent
            //       edit only invalidates the slice that touched it.
            return IntentGraph.build(from: compileEntries.map(\.intent))
        }
    }

    /// Drop everything in the cache. Called from app-level lifecycle
    /// hooks (sign-out, calendar disconnect).
    func invalidateAll() {
        compileDB.invalidateAll()
        graphDB.invalidateAll()
        registeredInputs.withLock { $0.removeAll() }
    }

    /// Number of cached whole-graph entries. Surfaced for tests and
    /// telemetry — `compileDB` cached count is `intentCount` after
    /// the first call, which isn't independently informative.
    var cachedGraphCount: Int { graphDB.cachedCount }

    // MARK: - Internals

    /// Per-intent compile query. Pure function of the intent only —
    /// the closure reads the intent's input key and computes the
    /// derived metadata. Cached entries stay valid across whole-
    /// graph queries that share the intent.
    private func compile(_ intent: ScheduleIntent, tracker: QueryTracker) -> IntentCompileEntry {
        let key = Self.compileKey(for: intent)
        let queryName = QueryKey("intentGraph.compile", Self.compileQueryName(for: intent))
        // Track that the outer (whole-graph) query depends on this
        // intent's input key.
        tracker.read(key)
        return compileDB.query(queryName) { innerTracker in
            innerTracker.read(key)
            // We intentionally hand `IntentGraph`'s static helpers
            // an empty graph reference — they're pure functions that
            // only read the intent argument.
            return IntentCompileEntry(
                intent: intent,
                nodeId: Self.canonicalNodeId(for: intent),
                phase: IntentGraph.phase(for: intent),
                dependencies: IntentGraph.dependencies(for: intent),
                suggestions: IntentGraph.suggestions(for: intent)
            )
        }
    }

    /// Register newly-seen input keys with the underlying QueryDBs.
    /// Already-registered keys are skipped so we don't bump revision
    /// for inputs that haven't actually changed.
    private func registerNewInputs(_ keys: [QueryKey]) {
        registeredInputs.withLock { state in
            for key in keys {
                if state.insert(key.identifier).inserted {
                    self.compileDB.setInput(key)
                    self.graphDB.setInput(key)
                }
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

    /// Query name for a per-intent compile call. Same identifier as
    /// the input key (different domain) so a cached compile entry's
    /// dep set is just `{compileKey(for: intent)}`.
    private static func compileQueryName(for intent: ScheduleIntent) -> String {
        canonicalNodeId(for: intent)
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
