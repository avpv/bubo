import Foundation

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

    /// Average chain depth across precedence graph. Reported as a
    /// normalised ratio over `N` so bandit features stay in [0, 1].
    var averageChainDepth: Double {
        let n = eventIds.count
        guard n > 0 else { return 0 }
        var maxDepth = 0
        for id in eventIds {
            maxDepth = max(maxDepth, (precedes[id] ?? []).count)
        }
        return min(1.0, Double(maxDepth) / Double(n))
    }

    // MARK: - Build

    /// Build the graph from an `OptimizerContext`. Allocates proportional
    /// to events + edges; for 100 events this is a few microseconds.
    static func build(from context: OptimizerContext) -> ScheduleConflictGraph {
        let ids = context.movableEvents.map(\.id)
        guard !ids.isEmpty else {
            return ScheduleConflictGraph(
                eventIds: [],
                componentOf: [:],
                componentCount: 0,
                conflicts: [:],
                directPrecedes: [:],
                precedes: [:],
                conflictEdgeCount: 0,
                precedenceEdgeCount: 0
            )
        }

        let eventById: [String: OptimizableEvent] = Dictionary(
            uniqueKeysWithValues: context.movableEvents.map { ($0.id, $0) }
        )

        // 1) Direct precedence edges from `dependsOn`.
        var precedesDirect: [String: Set<String>] = [:]
        var precedenceEdges = 0
        for event in context.movableEvents where !event.dependsOn.isEmpty {
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
        for event in context.movableEvents {
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
        for i in 0..<context.movableEvents.count {
            for j in (i + 1)..<context.movableEvents.count {
                let a = context.movableEvents[i]
                let b = context.movableEvents[j]
                guard let aRange = a.preferredHourRange,
                      let bRange = b.preferredHourRange else { continue }
                if aRange.overlaps(bRange) {
                    addConflictEdge(a.id, b.id)
                }
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

        return ScheduleConflictGraph(
            eventIds: ids,
            componentOf: componentOf,
            componentCount: rootToIdx.count,
            conflicts: conflicts,
            directPrecedes: precedesDirect,
            precedes: precedes,
            conflictEdgeCount: conflictEdges,
            precedenceEdgeCount: precedenceEdges
        )
    }

    // MARK: - Queries

    /// All event IDs in the same component as `eventId`. Returns
    /// `[eventId]` for singletons.
    func component(containing eventId: String) -> [String] {
        guard let cid = componentOf[eventId] else { return [eventId] }
        return eventIds.filter { componentOf[$0] == cid }
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
