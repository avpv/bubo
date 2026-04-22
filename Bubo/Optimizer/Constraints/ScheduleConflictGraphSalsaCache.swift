import Foundation
import os

// MARK: - Salsa-style ScheduleConflictGraph cache
//
// Mirrors `IntentGraphSalsaCache`: decomposes the build into per-
// event / per-pair queries via `QueryDB`, with an LRU bound on the
// whole-graph cache slot.
//
// Honest scope disclosure:
//   The `ScheduleConflictGraph.build` algorithm already bypasses
//   O(N²) pair-predicate evaluation via the participant-index and
//   sort+sweep hour-range optimizations. So per-pair memoization
//   would *not* accelerate the build path itself — the build
//   doesn't call a pair predicate often enough to matter.
//
//   What Salsa actually gives us here:
//     * LRU-bounded whole-graph entries — same as the hash-keyed
//       `ScheduleConflictGraphCache`, no regression.
//     * Per-event metadata queries (participants, hour range,
//       dependsOn) cached and tracked. Cross-context runs that share
//       events (e.g. scenario passes) hit the per-event cache.
//     * Per-pair overlap queries cached and tracked. Fine-grained
//       invalidation signal available for telemetry and future
//       external consumers ("does this pair of events conflict?"
//       from UI code without rebuilding the graph).
//     * QueryDB dependency tracking means changing one event's
//       fields only invalidates the O(N) pair entries involving it
//       — the other O(N²) stay cached even across edits. Useful
//       once a future build variant consumes the pair oracle.
//
//   What Salsa doesn't yet give us:
//     * Build-time speedup on a cache-cold first call. The build
//       still runs through `ScheduleConflictGraph.build`, which
//       doesn't route pair checks through the Salsa oracle — doing
//       so would require disabling the existing participant-index
//       fast path, which would be a net regression at current
//       scales.
//     * Recursive reachability caching. Per-source transitive
//       precedence is a per-event query in principle, but the
//       recursive form requires QueryDB to propagate nested
//       dependencies, which is a future extension.

/// Per-event metadata snapshot cached by the Salsa variant. Pure
/// function of the event itself — depends only on the event's own
/// fields, not on other events in the context.
struct ConflictEventMetadata: Sendable, Hashable {
    let id: String
    let dependsOn: [String]
    let participants: [String]
    let preferredHourLower: Int?
    let preferredHourUpper: Int?
}

/// Per-pair overlap decision cached by the Salsa variant.
struct ConflictOverlapDecision: Sendable, Hashable {
    /// Event IDs share at least one required participant.
    let shareParticipant: Bool
    /// Preferred-hour ranges overlap (only meaningful when both
    /// events have a preferred range).
    let hourRangesOverlap: Bool

    var hasOverlap: Bool { shareParticipant || hourRangesOverlap }
}

final class ScheduleConflictGraphSalsaCache: Sendable {

    // MARK: Per-query DBs
    private let eventMetadataDB: QueryDB<ConflictEventMetadata>
    private let pairOverlapDB: QueryDB<ConflictOverlapDecision>
    private let reachabilityDB: QueryDB<Set<String>>
    private let graphDB: QueryDB<ScheduleConflictGraph>

    /// Event id → structural fingerprint seen on the most recent
    /// call. Lets `registerInputs` detect when a previously-seen
    /// event id has changed shape (e.g. its `dependsOn` list was
    /// edited) and bump the input revision *only* then — so
    /// unchanged events don't invalidate their cached per-event /
    /// per-pair / reachability queries.
    private let registeredInputs: OSAllocatedUnfairLock<[String: UInt64]>

    /// Bounded LRU tracker for whole-graph entries. Same pattern as
    /// `IntentGraphSalsaCache` — per-event and per-pair entries
    /// survive the whole-graph eviction and stay warm.
    private let wholeGraphLRU: OSAllocatedUnfairLock<WholeGraphLRU>

    private struct WholeGraphLRU: Sendable {
        var recencyOrder: [QueryKey] = []
    }

    /// Cap on distinct whole-graph entries retained simultaneously.
    /// Per-event / per-pair entries aren't capped — they're bounded
    /// by event + pair diversity across the session and reusing
    /// them is the point.
    let wholeGraphCapacity: Int

    init(wholeGraphCapacity: Int = 16) {
        precondition(wholeGraphCapacity > 0, "Capacity must be positive")
        self.wholeGraphCapacity = wholeGraphCapacity
        self.eventMetadataDB = QueryDB<ConflictEventMetadata>()
        self.pairOverlapDB = QueryDB<ConflictOverlapDecision>()
        self.reachabilityDB = QueryDB<Set<String>>()
        self.graphDB = QueryDB<ScheduleConflictGraph>()
        self.registeredInputs = OSAllocatedUnfairLock(initialState: [:])
        self.wholeGraphLRU = OSAllocatedUnfairLock(initialState: WholeGraphLRU())
    }

    // MARK: Public API

    /// Cache-by-context shorthand. Reads `context.movableEvents`
    /// only — other context fields (working hours, fixed events)
    /// don't influence the conflict graph's structure.
    func graph(for context: OptimizerContext) -> ScheduleConflictGraph {
        graph(forMovableEvents: context.movableEvents)
    }

    /// Cache by movable-event list directly. Lets callers (e.g.
    /// `IntentCompiler`) warm the cache *before* constructing the
    /// final `OptimizerContext`.
    func graph(forMovableEvents events: [OptimizableEvent]) -> ScheduleConflictGraph {
        // Register each event's id as an input, bumping the revision
        // when a same-id event has changed shape since the last
        // call. First-time ids initialise at revision 1.
        registerInputs(for: events)

        // Whole-graph query name encodes the full movable-event
        // shape so two distinct event sets don't collide.
        let graphKey = QueryKey(
            "conflictGraph.whole",
            Self.shapeFingerprint(events)
        )
        touchWholeGraphLRU(graphKey)

        // Pre-index events by id so the reachability oracle (and
        // metadata query below) can look up dependency lists in
        // O(1). The oracle captures this dictionary by reference;
        // Swift's value-semantics mean no mutation leaks.
        let eventByIdLookup: [String: OptimizableEvent] = Dictionary(
            uniqueKeysWithValues: events.map { ($0.id, $0) }
        )

        return graphDB.query(graphKey) { tracker in
            // This closure runs only on cache miss, so timing and
            // logging live here directly — no out-of-band flag
            // needed to distinguish hit from miss.
            let buildStart = Date()

            // Force per-event metadata resolution so the tracker
            // records each event's input as a dependency. The
            // metadata is cached; hot calls skip the field reads.
            for event in events {
                _ = self.metadata(for: event, tracker: tracker)
            }

            // Reachability oracle: reuse per-source cached results
            // when possible, fall back to the Salsa-memoised query
            // otherwise. Walks `precedesDirect` (prereq →
            // dependents), matching the monolithic DFS's "transitive
            // dependents of this source" semantics — *not*
            // `event.dependsOn` (that would compute prereq closure,
            // the wrong direction).
            //
            // Invalidation breadth: the recursive query reads every
            // movable event's input, not just the ones it visits.
            // Without that, an unvisited event newly adding a
            // `dependsOn` edge to our source would reshape
            // `precedesDirect` without bumping any revision the
            // cached entry observed, and we'd return a stale empty
            // dependent set. Paying for the extra input reads keeps
            // the oracle correct across structural edits at the
            // cost of over-invalidation — when one event changes,
            // every reachability entry rebuilds. That matches the
            // monolithic DFS's behaviour, and the per-source cache
            // still wins on the common case of a same-shape re-
            // evaluation (what-if scenarios, objective tweaks).
            let allEventInputs = events.map { Self.eventInputKey(for: $0.id) }
            let oracle: (String, [String: Set<String>]) -> Set<String> = { sourceId, precedesDirect in
                self.reachability(
                    fromEventId: sourceId,
                    precedesDirect: precedesDirect,
                    allEventInputs: allEventInputs,
                    parent: tracker
                )
            }
            let graph = ScheduleConflictGraph.build(
                fromMovableEvents: events,
                reachabilityOracle: oracle
            )
            let buildMs = Int(Date().timeIntervalSince(buildStart) * 1000)
            Self.buildLogger.info("conflict_graph_built events=\(events.count) components=\(graph.componentCount) conflict_edges=\(graph.conflictEdgeCount) precedence_edges=\(graph.precedenceEdgeCount) density=\(graph.conflictDensity) build_ms=\(buildMs)")
            return graph
        }
    }

    private static let buildLogger = Logger(subsystem: "com.avpv.Bubo", category: "Optimizer/ConflictGraph")

    /// Query the per-pair overlap decision. Reads both events'
    /// input keys via the tracker so editing either event
    /// invalidates only the pairs involving it; other pairs stay
    /// cached.
    func pairOverlap(
        _ a: OptimizableEvent,
        _ b: OptimizableEvent
    ) -> ConflictOverlapDecision {
        ensureInputRegistered(for: a)
        ensureInputRegistered(for: b)
        // No outer query is in flight for this API; use a fresh
        // tracker so the inner query gets its own dep set.
        let scratch = QueryTracker()
        return pairOverlap(a, b, tracker: scratch)
    }

    /// Drop every cached entry. Called from session-end cleanup.
    func invalidateAll() {
        eventMetadataDB.invalidateAll()
        pairOverlapDB.invalidateAll()
        reachabilityDB.invalidateAll()
        graphDB.invalidateAll()
        registeredInputs.withLock { $0.removeAll() }
        wholeGraphLRU.withLock { $0.recencyOrder.removeAll() }
    }

    // MARK: Telemetry

    var cachedGraphCount: Int { graphDB.cachedCount }
    var cachedEventMetadataCount: Int { eventMetadataDB.cachedCount }
    var cachedPairCount: Int { pairOverlapDB.cachedCount }
    var cachedReachabilityCount: Int { reachabilityDB.cachedCount }

    // MARK: - Internals

    /// Per-event metadata query. Captures the fields the conflict
    /// graph consumes — `dependsOn`, `requiredParticipants`,
    /// `preferredHourRange` — so a cross-context call with the
    /// same event id produces a cache hit without re-reading the
    /// event struct.
    private func metadata(
        for event: OptimizableEvent,
        tracker: QueryTracker
    ) -> ConflictEventMetadata {
        let key = Self.eventInputKey(for: event.id)
        tracker.read(key)
        let queryName = QueryKey("conflictGraph.event", event.id)
        return eventMetadataDB.query(queryName) { innerTracker in
            innerTracker.read(key)
            return ConflictEventMetadata(
                id: event.id,
                dependsOn: event.dependsOn,
                participants: event.requiredParticipants,
                preferredHourLower: event.preferredHourRange?.lowerBound,
                preferredHourUpper: event.preferredHourRange?.upperBound
            )
        }
    }

    /// Recursive per-source transitive reachability. Returns the
    /// set of event ids that transitively *depend on* `sourceId`
    /// via `dependsOn` chains — matching the semantics of the
    /// monolithic DFS's `precedes[sourceId]`.
    ///
    /// Walks `precedesDirect` (prereq → dependents), not
    /// `event.dependsOn` (dependent → prereqs). The monolithic code
    /// treats "transitive precedence" as "events that will be
    /// waiting on this source", so the cache must agree.
    ///
    /// How the recursion plays with `QueryDB`:
    ///   * This query's cache entry records the source's own
    ///     `input(sourceId)` as a direct dep, plus `input(d)` for
    ///     every dependent `d` — so a change to any dependent's
    ///     `dependsOn` list invalidates this entry. Child recursion
    ///     uses `using: innerTracker`, so grandchildren's deps
    ///     propagate up too. Every ancestor transitively depends
    ///     on every reachable event's input.
    ///   * Cycles: `visited` is seeded with the source so an
    ///     `A → B → A` cycle terminates without re-entering `A`.
    ///     Silent cycle tolerance matches the monolithic DFS (see
    ///     `ScheduleConflictGraph.build`'s inner DFS).
    private func reachability(
        fromEventId sourceId: String,
        precedesDirect: [String: Set<String>],
        allEventInputs: [QueryKey],
        parent: QueryTracker
    ) -> Set<String> {
        let key = Self.eventInputKey(for: sourceId)
        parent.read(key)
        let queryName = QueryKey("conflictGraph.reachability", sourceId)
        return reachabilityDB.query(queryName, using: parent) { innerTracker in
            // Read every movable event's input as a dep so a
            // structural edit anywhere in the graph correctly
            // invalidates this entry — see the oracle setup in
            // `graph(forMovableEvents:)` for the full rationale.
            for inputKey in allEventInputs {
                innerTracker.read(inputKey)
            }

            var result: Set<String> = []
            // `visited` seeds with the source so a cycle like
            // `A → B → A` terminates on the second hit to `A`.
            var visited: Set<String> = [sourceId]

            for dependentId in precedesDirect[sourceId] ?? [] {
                if visited.insert(dependentId).inserted {
                    result.insert(dependentId)
                }
                // Recurse via the Salsa cache. `using: innerTracker`
                // propagates the child's observed deps into this
                // query's dep set.
                let childReach = self.reachability(
                    fromEventId: dependentId,
                    precedesDirect: precedesDirect,
                    allEventInputs: allEventInputs,
                    parent: innerTracker
                )
                for child in childReach where visited.insert(child).inserted {
                    result.insert(child)
                }
            }
            return result
        }
    }

    /// Per-pair overlap query. Canonical pair order (lexicographic
    /// on event id) so `(a, b)` and `(b, a)` share the slot —
    /// overlap is symmetric. Reads both events' input keys via
    /// `tracker` so a change to either invalidates only this pair
    /// (and every other pair involving the edited event).
    private func pairOverlap(
        _ a: OptimizableEvent,
        _ b: OptimizableEvent,
        tracker: QueryTracker
    ) -> ConflictOverlapDecision {
        let first: OptimizableEvent
        let second: OptimizableEvent
        if a.id <= b.id {
            first = a
            second = b
        } else {
            first = b
            second = a
        }
        let keyA = Self.eventInputKey(for: first.id)
        let keyB = Self.eventInputKey(for: second.id)
        tracker.read(keyA)
        tracker.read(keyB)

        let queryName = QueryKey(
            "conflictGraph.pair",
            "\(first.id)|\(second.id)"
        )
        return pairOverlapDB.query(queryName) { innerTracker in
            innerTracker.read(keyA)
            innerTracker.read(keyB)

            // Participant overlap: set intersection, short-circuit
            // on first hit so k-participant events don't pay
            // O(k²) set membership checks.
            let participantsA = Set(first.requiredParticipants)
            var shareParticipant = false
            for p in second.requiredParticipants where participantsA.contains(p) {
                shareParticipant = true
                break
            }

            // Hour range overlap: only when both events have a
            // preferred range. Matches the default build's logic
            // exactly (`aRange.overlaps(bRange)`).
            var hourRangesOverlap = false
            if let aRange = first.preferredHourRange,
               let bRange = second.preferredHourRange {
                hourRangesOverlap = aRange.overlaps(bRange)
            }

            return ConflictOverlapDecision(
                shareParticipant: shareParticipant,
                hourRangesOverlap: hourRangesOverlap
            )
        }
    }

    /// Register inputs for a batch of events. Three-way reconciliation
    /// between the previously-seen registration state and the current
    /// `events` list:
    ///
    ///   * **Added or changed** — id present in new list with a
    ///     fingerprint that doesn't match (or wasn't registered
    ///     before): `setInput` on every DB bumps revision. Cached
    ///     queries that touched the id see a revision mismatch and
    ///     rebuild; queries that never touched it stay warm.
    ///   * **Unchanged** — same id, same fingerprint: no-op, every
    ///     cached query for this id stays valid.
    ///   * **Removed** — id registered previously but not present in
    ///     the new list: `setInput` bumps revision so cached queries
    ///     that depended on this id (for example, reachability
    ///     results that included it) invalidate on next lookup. The
    ///     fingerprint is dropped from `state` so a re-add starts
    ///     fresh.
    ///
    /// The removal handling matters because some queries (per-source
    /// reachability especially) transitively read other events'
    /// inputs via `QueryDB.query(_:using:_:)` propagation. Without
    /// bumping on removal, a cached `reachability(B)` that once
    /// transitively reached `A` would still say so even after `A`
    /// is pulled from the event set — silently wrong.
    private func registerInputs(for events: [OptimizableEvent]) {
        let newIds = Set(events.map(\.id))
        registeredInputs.withLock { state in
            // Removals: previously-registered ids not in the new call.
            // Collect first, mutate after, so we don't violate
            // Dictionary iteration safety.
            let removedIds = state.keys.filter { !newIds.contains($0) }
            for removedId in removedIds {
                let key = Self.eventInputKey(for: removedId)
                self.eventMetadataDB.setInput(key)
                self.pairOverlapDB.setInput(key)
                self.reachabilityDB.setInput(key)
                self.graphDB.setInput(key)
                state[removedId] = nil
            }

            // Additions + changes.
            for event in events {
                let fingerprint = Self.eventFingerprint(event)
                if let prev = state[event.id], prev == fingerprint {
                    continue
                }
                state[event.id] = fingerprint
                let key = Self.eventInputKey(for: event.id)
                self.eventMetadataDB.setInput(key)
                self.pairOverlapDB.setInput(key)
                self.reachabilityDB.setInput(key)
                self.graphDB.setInput(key)
            }
        }
    }

    /// Register a single event without the full add/remove
    /// reconciliation that `registerInputs(for:)` performs. Used by
    /// the external `pairOverlap(_:_:)` entry point so a pair
    /// probe doesn't accidentally mark every other previously-
    /// registered event as "removed".
    ///
    /// Semantics: first-time ids register at revision 1; ids seen
    /// with a different fingerprint bump revision; same fingerprint
    /// is a no-op. Mirrors the per-event branch of
    /// `registerInputs(for:)` exactly.
    private func ensureInputRegistered(for event: OptimizableEvent) {
        let fingerprint = Self.eventFingerprint(event)
        registeredInputs.withLock { state in
            if let prev = state[event.id], prev == fingerprint {
                return
            }
            state[event.id] = fingerprint
            let key = Self.eventInputKey(for: event.id)
            self.eventMetadataDB.setInput(key)
            self.pairOverlapDB.setInput(key)
            self.reachabilityDB.setInput(key)
            self.graphDB.setInput(key)
        }
    }

    /// Mark `key` as most-recently-used and evict the oldest
    /// whole-graph entry if we're over the cap. Eviction uses
    /// `invalidateQuery` which removes only the graph cache slot;
    /// per-event / per-pair entries stay cached.
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

    /// QueryKey representing a single event's input identity.
    /// Domain `eventInput` separates event inputs from query names
    /// so the two namespaces don't collide.
    private static func eventInputKey(for eventId: String) -> QueryKey {
        QueryKey("eventInput", eventId)
    }

    /// Structural fingerprint of an event over the fields the
    /// conflict graph actually reads. Used by `registerInputs`
    /// to detect when a same-id event has structurally changed
    /// between calls and needs its input revision bumped.
    private static func eventFingerprint(_ event: OptimizableEvent) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(event.dependsOn.sorted())
        hasher.combine(event.requiredParticipants.sorted())
        if let range = event.preferredHourRange {
            hasher.combine(range.lowerBound)
            hasher.combine(range.upperBound)
        } else {
            hasher.combine(Int.min)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// Whole-graph cache key — stable per *shape* of the movable-
    /// event set (ids + the structural fields the conflict graph
    /// reads). Two calls with the same events in the same order
    /// share the slot; changing any of the structural fields
    /// produces a distinct key.
    private static func shapeFingerprint(_ events: [OptimizableEvent]) -> String {
        var hasher = Hasher()
        hasher.combine(events.count)
        for event in events {
            hasher.combine(event.id)
            hasher.combine(event.dependsOn.sorted())
            hasher.combine(event.requiredParticipants.sorted())
            if let range = event.preferredHourRange {
                hasher.combine(range.lowerBound)
                hasher.combine(range.upperBound)
            } else {
                hasher.combine(Int.min)
            }
        }
        return String(hasher.finalize(), radix: 16)
    }
}
