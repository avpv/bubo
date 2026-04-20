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
    private let graphDB: QueryDB<ScheduleConflictGraph>

    /// Which event ids the cache has registered as inputs. Guarded
    /// for concurrent callers from parallel GA evaluators.
    private let registeredInputs: OSAllocatedUnfairLock<Set<String>>

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
        self.graphDB = QueryDB<ScheduleConflictGraph>()
        self.registeredInputs = OSAllocatedUnfairLock(initialState: [])
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
        // Register each event's id as an input. First-time ids get
        // revision 1; ids already registered keep their revision.
        let eventKeys = events.map { Self.eventInputKey(for: $0.id) }
        registerNewInputs(eventKeys)

        // Whole-graph query name encodes the full movable-event
        // shape so two distinct event sets don't collide.
        let graphKey = QueryKey(
            "conflictGraph.whole",
            Self.shapeFingerprint(events)
        )
        touchWholeGraphLRU(graphKey)

        return graphDB.query(graphKey) { tracker in
            // Force per-event metadata resolution so the tracker
            // records each event's input as a dependency. The
            // metadata is cached; hot calls skip the field reads.
            for event in events {
                _ = self.metadata(for: event, tracker: tracker)
            }
            // Build still uses the monolithic algorithm — its
            // participant-index and hour-bucketing fast paths
            // already beat what per-pair memoization could offer
            // on a cold build. Pair-level caching is available via
            // `pairOverlap(_:_:)` for external consumers.
            return ScheduleConflictGraph.build(fromMovableEvents: events)
        }
    }

    /// Query the per-pair overlap decision. Reads both events'
    /// input keys via the tracker so editing either event
    /// invalidates only the pairs involving it; other pairs stay
    /// cached.
    func pairOverlap(
        _ a: OptimizableEvent,
        _ b: OptimizableEvent
    ) -> ConflictOverlapDecision {
        registerNewInputs([Self.eventInputKey(for: a.id), Self.eventInputKey(for: b.id)])
        // No outer query is in flight for this API; use a fresh
        // tracker so the inner query gets its own dep set.
        let scratch = QueryTracker()
        return pairOverlap(a, b, tracker: scratch)
    }

    /// Drop every cached entry. Called from session-end cleanup.
    func invalidateAll() {
        eventMetadataDB.invalidateAll()
        pairOverlapDB.invalidateAll()
        graphDB.invalidateAll()
        registeredInputs.withLock { $0.removeAll() }
        wholeGraphLRU.withLock { $0.recencyOrder.removeAll() }
    }

    // MARK: Telemetry

    var cachedGraphCount: Int { graphDB.cachedCount }
    var cachedEventMetadataCount: Int { eventMetadataDB.cachedCount }
    var cachedPairCount: Int { pairOverlapDB.cachedCount }

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

    /// Register newly-seen input keys across every underlying
    /// QueryDB. Already-registered keys are skipped so unchanged
    /// events don't have their revision bumped.
    private func registerNewInputs(_ keys: [QueryKey]) {
        registeredInputs.withLock { state in
            for key in keys {
                if state.insert(key.identifier).inserted {
                    self.eventMetadataDB.setInput(key)
                    self.pairOverlapDB.setInput(key)
                    self.graphDB.setInput(key)
                }
            }
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
