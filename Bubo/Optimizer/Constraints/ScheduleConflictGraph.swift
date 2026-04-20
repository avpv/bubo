import Foundation
import os

// MARK: - Schedule Conflict Graph
//
// Precomputes which pairs of movable events can ever conflict based on
// static attributes (required participants, duration exceeding a single
// day, etc.) plus an interval index keyed on horizon day. Consumers in
// the GA query it instead of the old O(N²) pairwise sweep every
// generation:
//
//   * Repair: only check occupancy against the interval-indexed
//     fixed-event and peer-gene lists per day, not against the full
//     schedule.
//   * Objective decomposition: weakly-connected components of the
//     graph determine which genes can be scored together — a mutation
//     that only touches component A can't affect objective scores on
//     component B.
//   * Mutation bandit features: conflict density is a cheap descriptor
//     of how structurally constrained the current landscape is.
//
// Why a dedicated graph at all when constraints already detect
// overlaps? The constraint engine runs *during* fitness evaluation and
// always walks the full gene list. The graph is a *preprocessing*
// artefact: it runs once per optimizer context, answers "what could
// ever touch what?" in O(1) per query, and lets hot paths prune work
// before hitting the O(N²) overlap test.

/// Indexed conflict/precedence graph over an optimizer context.
///
/// `weaklyConnectedComponents` groups event IDs whose scheduling
/// decisions might actually interact (shared participant, chained
/// via `dependsOn`, overlapping preferred hour windows). Mutations
/// and objective evaluations can use the component ID as a cache
/// invalidation key instead of "the whole schedule".
struct ScheduleConflictGraph: Sendable {

    // MARK: - Structure

    /// Every movable event ID, in the order they appear in the
    /// context's `movableEvents`.
    let eventIds: [String]

    /// event ID → component ID (0-based). Events in the same component
    /// share at least one participant, a dependency edge, or an
    /// overlapping preferred-hour window.
    let componentOf: [String: Int]

    /// Count of components (≥ 1 when events exist).
    let componentCount: Int

    /// event ID → set of event IDs it conflicts with directly.
    let conflicts: [String: Set<String>]

    /// event ID → set of event IDs it directly precedes (one hop of
    /// `dependsOn`). Used for cheap iteration during tightness
    /// evaluation and component union.
    let directPrecedes: [String: Set<String>]

    /// event ID → set of event IDs it precedes transitively.
    let precedes: [String: Set<String>]

    /// Total edges in the conflict layer — used by bandit features to
    /// express "how densely connected is the landscape?" as a scalar.
    let conflictEdgeCount: Int

    /// Total `dependsOn` edges (direct, not transitive).
    let precedenceEdgeCount: Int

    /// Lazy bitset-backed transitive precedence index. Same content
    /// as `precedes` but stored as `[UInt64]` words per event so the
    /// GA can answer "does A precede B?" with a single bit test
    /// instead of `Set<String>.contains`. Built on first access via
    /// the holder so callers that never query reachability don't pay
    /// the ~N²/64-byte allocation. `nil` for empty graphs.
    let precedesBitsetHolder: ReachabilityBitsetHolder?

    /// Force the bitset build and return it (or `nil` for empty
    /// graphs). Subsequent calls hit a cached value via
    /// `ReachabilityBitsetHolder`.
    var precedesBitset: ReachabilityBitset? { precedesBitsetHolder?.value() }

    // MARK: - Public diagnostics

    /// Conflict density in [0, 1]: `2 · edges / (N · (N-1))`. Zero
    /// means no pairwise constraints — the GA can ignore conflict
    /// objectives entirely. One means a fully-coupled landscape.
    var conflictDensity: Double {
        let n = eventIds.count
        guard n >= 2 else { return 0 }
        let maxEdges = Double(n) * Double(n - 1) / 2.0
        return min(1.0, Double(conflictEdgeCount) / maxEdges)
    }

    /// Deepest precedence chain (the maximum number of transitive
    /// descendants any single event has), normalised to `[0, 1]` by
    /// dividing by `eventIds.count` so bandit features stay in range.
    /// "Max" not "average" because the GA cares about the worst-case
    /// chain length when deciding whether a global day-move can
    /// legally reshuffle dependents — a bandit that learned on the
    /// wrong summary statistic would make the wrong choice.
    var maxChainDepth: Double {
        let n = eventIds.count
        guard n > 0 else { return 0 }
        var deepest = 0
        for id in eventIds {
            deepest = max(deepest, (precedes[id] ?? []).count)
        }
        return min(1.0, Double(deepest) / Double(n))
    }

    // MARK: - Build

    /// Build the graph from an `OptimizerContext`. Convenience over
    /// `build(fromMovableEvents:)` for callers that already have a
    /// context handy. The graph only depends on `movableEvents`; other
    /// context fields (working hours, fixed events, preferences)
    /// don't influence its structure.
    static func build(from context: OptimizerContext) -> ScheduleConflictGraph {
        build(fromMovableEvents: context.movableEvents)
    }

    /// Build the graph directly from a movable-event list. Lets the
    /// graph cache warm without constructing a throwaway
    /// `OptimizerContext`, and makes the (movable events → graph)
    /// dependency explicit at the type level instead of buried in the
    /// context boilerplate.
    ///
    /// Allocates proportional to events + edges; for 100 events this
    /// is a few microseconds.
    ///
    /// `Dictionary(uniqueKeysWithValues:)` below traps on duplicates,
    /// so we build the internal maps against a de-duplicated event
    /// list. Callers (`IntentCompiler.execute`) already dedupe; this
    /// is defence-in-depth so a future collision becomes a silently-
    /// correct placement instead of a runtime crash.
    static func build(fromMovableEvents events: [OptimizableEvent]) -> ScheduleConflictGraph {
        var seen: Set<String> = []
        let uniqueEvents = events.filter { seen.insert($0.id).inserted }
        let ids = uniqueEvents.map(\.id)
        guard !ids.isEmpty else {
            return ScheduleConflictGraph(
                eventIds: [],
                componentOf: [:],
                componentCount: 0,
                conflicts: [:],
                directPrecedes: [:],
                precedes: [:],
                conflictEdgeCount: 0,
                precedenceEdgeCount: 0,
                precedesBitsetHolder: nil
            )
        }

        let eventById: [String: OptimizableEvent] = Dictionary(
            uniqueKeysWithValues: uniqueEvents.map { ($0.id, $0) }
        )

        // 1) Direct precedence edges from `dependsOn`.
        var precedesDirect: [String: Set<String>] = [:]
        var precedenceEdges = 0
        for event in uniqueEvents where !event.dependsOn.isEmpty {
            for depId in event.dependsOn {
                // Dependency may point at another movable event or a
                // fixed one; only movable → movable edges participate
                // in component analysis (fixed events never move, so
                // they can't be in a "same component" with a movable).
                guard eventById[depId] != nil else { continue }
                precedesDirect[depId, default: []].insert(event.id)
                precedenceEdges += 1
            }
        }

        // 2) Transitive precedence via DFS.
        var precedes: [String: Set<String>] = [:]
        for id in ids {
            var visited: Set<String> = []
            var stack = Array(precedesDirect[id] ?? [])
            while let head = stack.popLast() {
                guard visited.insert(head).inserted else { continue }
                if let downstream = precedesDirect[head] {
                    stack.append(contentsOf: downstream)
                }
            }
            precedes[id] = visited
        }

        // 3) Conflict edges: pairs that can ever collide on structural
        //    grounds. A time overlap alone isn't here — the constraint
        //    engine handles that during evaluation. This layer is for
        //    the "can never coexist no matter what" pairs that tell
        //    components apart.
        var conflicts: [String: Set<String>] = [:]
        var conflictEdges = 0

        // Participant index: two events that require the same person
        // conflict whenever they overlap, so they share a component.
        var participantIndex: [String: [String]] = [:]
        for event in uniqueEvents {
            for person in event.requiredParticipants {
                participantIndex[person, default: []].append(event.id)
            }
        }

        // Helper: add an undirected conflict edge, incrementing the
        // edge count only on the first insertion (pairs are symmetric
        // so we don't want to count twice).
        func addConflictEdge(_ a: String, _ b: String) {
            var aSet = conflicts[a] ?? []
            if aSet.insert(b).inserted {
                conflictEdges += 1
            }
            conflicts[a] = aSet
            var bSet = conflicts[b] ?? []
            bSet.insert(a)
            conflicts[b] = bSet
        }

        for (_, attendeeEvents) in participantIndex where attendeeEvents.count > 1 {
            for i in 0..<attendeeEvents.count {
                for j in (i + 1)..<attendeeEvents.count {
                    addConflictEdge(attendeeEvents[i], attendeeEvents[j])
                }
            }
        }

        // Preferred-hour overlap (soft coupling) — events that prefer
        // overlapping windows get bucketed together for component
        // analysis even without a hard constraint.
        //
        // Old impl was a naive O(N²) double sweep over every event
        // pair, paying the `guard let aRange / bRange` cost even on
        // events without a preferred range. Now we (1) filter the list
        // down to events that *have* a range and (2) sort by lower
        // bound so the inner sweep can break the moment the next
        // candidate's lower bound passes our upper bound. For real
        // calendars where ranges cluster (e.g. focus blocks 9-12,
        // meetings 14-17), this turns into ~O(N · k) with k = local
        // overlap-cluster size.
        let ranged = uniqueEvents
            .compactMap { event -> (id: String, range: ClosedRange<Int>)? in
                guard let range = event.preferredHourRange else { return nil }
                return (event.id, range)
            }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }

        for i in 0..<ranged.count {
            let a = ranged[i]
            var j = i + 1
            while j < ranged.count {
                let b = ranged[j]
                // `ranged` is sorted ascending by lowerBound; once
                // `b.lowerBound > a.upperBound` no later element can
                // overlap a either, so we cut the inner loop short.
                if b.range.lowerBound > a.range.upperBound { break }
                addConflictEdge(a.id, b.id)
                j += 1
            }
        }

        // 4) Weakly-connected components via union-find.
        var parent: [String: String] = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
        func find(_ x: String) -> String {
            var cur = x
            while parent[cur] != cur { cur = parent[cur]! }
            // Path compression.
            var walker = x
            while parent[walker] != cur {
                let next = parent[walker]!
                parent[walker] = cur
                walker = next
            }
            return cur
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        for (a, neighbours) in conflicts {
            for b in neighbours { union(a, b) }
        }
        for (prereq, dependents) in precedesDirect {
            for d in dependents { union(prereq, d) }
        }

        var componentOf: [String: Int] = [:]
        var rootToIdx: [String: Int] = [:]
        for id in ids {
            let root = find(id)
            if let existing = rootToIdx[root] {
                componentOf[id] = existing
            } else {
                let idx = rootToIdx.count
                rootToIdx[root] = idx
                componentOf[id] = idx
            }
        }

        // 5) Bitset transitive precedence: same content as `precedes`
        //    but stored as one `[UInt64]` mask per row. Hot-path
        //    consumers (objective decomposition, repair preflight)
        //    can answer "does A precede B?" with a word/bit lookup
        //    instead of `Set.contains`. Built lazily — callers that
        //    never call `transitivelyPrecedes(_:_:)` skip the
        //    allocation entirely.
        let bitsetHolder = ReachabilityBitsetHolder(ids: ids, edges: precedes)

        return ScheduleConflictGraph(
            eventIds: ids,
            componentOf: componentOf,
            componentCount: rootToIdx.count,
            conflicts: conflicts,
            directPrecedes: precedesDirect,
            precedes: precedes,
            conflictEdgeCount: conflictEdges,
            precedenceEdgeCount: precedenceEdges,
            precedesBitsetHolder: bitsetHolder
        )
    }

    // MARK: - Queries

    /// All event IDs in the same component as `eventId`. Returns
    /// `[eventId]` for singletons.
    func component(containing eventId: String) -> [String] {
        guard let cid = componentOf[eventId] else { return [eventId] }
        return eventIds.filter { componentOf[$0] == cid }
    }

    /// Bitset-backed "does `prereq` transitively precede `dependent`?"
    /// query. O(1) on the hot path: one dictionary lookup for each id
    /// to translate to an integer index, then a word/bit test on the
    /// stored mask. Returns `false` for unknown event ids or when the
    /// bitset wasn't built (empty graph).
    func transitivelyPrecedes(_ prereq: String, _ dependent: String) -> Bool {
        guard let bitset = precedesBitset else { return false }
        return bitset.contains(from: prereq, to: dependent)
    }

    /// Every component as an array of member event IDs. Useful for
    /// decomposing global objectives into per-component sums.
    func allComponents() -> [[String]] {
        guard componentCount > 0 else { return [] }
        var buckets: [[String]] = Array(repeating: [], count: componentCount)
        for id in eventIds {
            if let cid = componentOf[id] {
                buckets[cid].append(id)
            }
        }
        return buckets
    }

    /// Normalised precedence tightness for a chromosome: fraction of
    /// direct precedence pairs whose gap is below `tightnessWindow`.
    /// 0 = every dependency loosely scheduled; 1 = every dependency
    /// placed immediately after its prerequisite. Used as a QD
    /// behavioural descriptor.
    func precedenceTightness(
        for chromosome: ScheduleChromosome,
        tightnessWindow: TimeInterval = 3600
    ) -> Double {
        guard precedenceEdgeCount > 0 else { return 0 }

        // Build a gene lookup once; precedence checks are O(edges) afterwards.
        var geneByEvent: [String: ScheduleGene] = [:]
        geneByEvent.reserveCapacity(chromosome.genes.count)
        for gene in chromosome.genes where gene.isIncluded {
            geneByEvent[gene.eventId] = gene
        }

        var tight = 0
        var total = 0
        for (prereq, dependents) in directPrecedes {
            for dep in dependents {
                guard let prereqGene = geneByEvent[prereq],
                      let depGene = geneByEvent[dep] else { continue }
                total += 1
                let gap = depGene.startTime.timeIntervalSince(prereqGene.endTime)
                if gap >= 0 && gap <= tightnessWindow {
                    tight += 1
                }
            }
        }
        guard total > 0 else { return 0 }
        return Double(tight) / Double(total)
    }
}

// MARK: - Holder (lazy cache)

/// Reference-type wrapper so `OptimizerContext` (a struct) can share
/// a single built graph across every copy. `ensureConflictGraph()`
/// goes through this holder, so fitness evaluators and mutation
/// operators pay the build cost exactly once per run instead of once
/// per chromosome evaluation.
///
/// Thread-safe: the GA evaluates offspring in parallel via
/// `DispatchQueue.concurrentPerform`, so several threads may race to
/// be the first caller. `OSAllocatedUnfairLock` keeps the "build
/// once" invariant without blocking readers once the graph is
/// cached, with ~3× cheaper acquire than `NSLock` and Swift 6
/// strict-concurrency support out of the box.
final class ConflictGraphHolder: Sendable {
    private let state: OSAllocatedUnfairLock<ScheduleConflictGraph?>

    init(preloaded: ScheduleConflictGraph? = nil) {
        self.state = OSAllocatedUnfairLock(initialState: preloaded)
    }

    /// Build-or-fetch the cached graph. Callers pass the context they
    /// want built from — the holder itself doesn't store one so it
    /// stays light and doesn't retain fixed/movable event arrays.
    func get(for context: OptimizerContext) -> ScheduleConflictGraph {
        // Fast path: a quick locked read.
        if let cached = state.withLock({ $0 }) {
            return cached
        }

        // Build outside the lock so concurrent callers don't serialize
        // on the actual computation. Two threads may build the graph
        // twice on first access; the "double-checked" store below
        // picks whichever arrives first. Both threads return the same
        // logical graph, so the duplicate is harmless.
        let built = ScheduleConflictGraph.build(from: context)

        return state.withLock { current in
            if let existing = current {
                return existing
            }
            current = built
            return built
        }
    }
}

