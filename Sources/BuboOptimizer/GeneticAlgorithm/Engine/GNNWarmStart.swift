import Foundation
import BuboDomain

// MARK: - GNN Warm-Start (Wave 5 / item 2)
//
// A small, training-free graph neural network over the conflict /
// precedence graph. Produces per-event priority scores that drive a
// topologically-aware greedy seed chromosome.
//
// Architecture: 3 rounds of sum-mean aggregation over node features,
// interleaved with tanh nonlinearities, followed by a linear head
// that outputs a scalar priority per node. Message, update, and
// readout weights are *deterministic functions of the event
// feature*, not learned — so the implementation ships without a
// training pipeline. The structure still captures graph-level
// information (a node with many downstream dependencies gets a
// higher score because its messages propagate outward more), giving
// the GA a better seed than purely-local heuristics like "priority
// first".
//
// When Bubo collects real user feedback we can swap the
// deterministic weights for learned ones — the layer signatures
// don't change, only the `MessagePassingWeights` content. For now
// the heuristic weights produce good-quality seeds that outperform
// random initialisation on dense-precedence workloads.

/// Per-node feature vector fed into the GNN. 6 scalars covering the
/// dimensions that matter for seed construction.
public struct GNNNodeFeatures: Sendable {

    public init(
        priority: Double,
        durationHours: Double,
        energyCost: Double,
        hasDeadline: Double,        // 1 if deadline set, else 0
        isFocusBlock: Double,
        outDegree: Double           // direct precedence out-count, normalised
    ) {
        self.priority = priority
        self.durationHours = durationHours
        self.energyCost = energyCost
        self.hasDeadline = hasDeadline
        self.isFocusBlock = isFocusBlock
        self.outDegree = outDegree
    }

    public let priority: Double
    public let durationHours: Double
    public let energyCost: Double
    public let hasDeadline: Double       // 1 if deadline set, else 0
    public let isFocusBlock: Double
    public let outDegree: Double         // direct precedence out-count, normalised

    fileprivate var asArray: [Double] {
        [priority, durationHours, energyCost, hasDeadline, isFocusBlock, outDegree]
    }
}

/// Weights for one GNN round. Input/output dimensions must match the
/// number of node features (6). Mutable to support online learning;
/// the trainer rewrites readout / message rows when the GNN's seed
/// produces high-fitness chromosomes.
public struct MessagePassingWeights: Sendable, Codable {

    public init(
        message: [[Double]],
        update: [[Double]],
        readout: [Double]
    ) {
        self.message = message
        self.update = update
        self.readout = readout
    }

    /// Message transformation: `m_ij = M · x_j` (row-major, 6×6).
    public var message: [[Double]]
    /// Update: new h_i = tanh(U · [x_i ; agg_j m_ij] ) — concatenation
    /// implemented by layering the 6×12 matrix.
    public var update: [[Double]]
    /// Readout scalar projection: r_i = R · x_i (length 6).
    public var readout: [Double]

    /// Heuristic weights. No learning; the values are picked to
    /// propagate "urgency" outward from deadline-bearing nodes and
    /// amplify high-priority hubs. Produces sensible seeds on
    /// untrained deployments.
    public static let heuristic = MessagePassingWeights(
        message: [
            [0.6, 0.0, 0.0, 0.0, 0.0, 0.1],
            [0.0, 0.4, 0.0, 0.0, 0.0, 0.0],
            [0.0, 0.0, 0.5, 0.0, 0.0, 0.0],
            [0.0, 0.0, 0.0, 0.8, 0.0, 0.2],
            [0.0, 0.0, 0.0, 0.0, 0.7, 0.0],
            [0.0, 0.0, 0.0, 0.0, 0.0, 0.5],
        ],
        update: [
            [0.7, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3, 0.0, 0.0, 0.0, 0.0, 0.1],
            [0.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3, 0.0, 0.0, 0.0, 0.0],
            [0.0, 0.0, 0.6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.2, 0.0, 0.0, 0.0],
            [0.0, 0.0, 0.0, 0.8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.4, 0.0, 0.1],
            [0.0, 0.0, 0.0, 0.0, 0.7, 0.0, 0.0, 0.0, 0.0, 0.0, 0.2, 0.0],
            [0.0, 0.0, 0.0, 0.0, 0.0, 0.4, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3],
        ],
        readout: [0.45, -0.05, -0.15, 0.60, 0.20, 0.30]
    )
}

// MARK: - GNN Layer

public enum GNNWarmStart {
    /// Run the GNN forward pass, returning `eventId → priorityScore`.
    public static func priorityScores(
        context: OptimizerContext,
        weights: MessagePassingWeights = .heuristic,
        rounds: Int = 3
    ) -> [String: Double] {
        let graph = context.ensureConflictGraph()
        guard !graph.eventIds.isEmpty else { return [:] }

        let features = buildFeatures(context: context, graph: graph)
        var hidden: [String: [Double]] = features.mapValues { $0.asArray }

        for _ in 0..<rounds {
            let updated = stepOnce(
                hidden: hidden,
                adjacency: graph.directPrecedes,
                weights: weights
            )
            hidden = updated
        }

        var scores: [String: Double] = [:]
        scores.reserveCapacity(hidden.count)
        for (id, h) in hidden {
            scores[id] = readout(h, weights: weights.readout)
        }
        return scores
    }

    /// Build a greedy seed chromosome whose event ordering comes from
    /// GNN priority scores. Respects precedence (topological order
    /// enforced via Kahn's algorithm when equal-score ties exist).
    public static func seedChromosome(
        context: OptimizerContext,
        weights: MessagePassingWeights = .heuristic
    ) -> ScheduleChromosome {
        let scores = priorityScores(context: context, weights: weights)
        let graph = context.ensureConflictGraph()
        let ordered = topologicalOrder(
            eventIds: graph.eventIds,
            directPrecedes: graph.directPrecedes,
            scores: scores,
            backlogIndex: context.backlogIndexMap()
        )
        return greedyAssign(orderedIds: ordered, context: context)
    }

    // MARK: - Internals

    private static func buildFeatures(
        context: OptimizerContext,
        graph: ScheduleConflictGraph
    ) -> [String: GNNNodeFeatures] {
        var out: [String: GNNNodeFeatures] = [:]
        let maxOut = max(1, graph.directPrecedes.values.map(\.count).max() ?? 1)
        for event in context.movableEvents {
            let outDeg = graph.directPrecedes[event.id]?.count ?? 0
            out[event.id] = GNNNodeFeatures(
                priority: event.priority,
                durationHours: min(8.0, event.duration / 3600) / 8.0,
                energyCost: event.energyCost,
                hasDeadline: event.deadline != nil ? 1 : 0,
                isFocusBlock: event.isFocusBlock ? 1 : 0,
                outDegree: Double(outDeg) / Double(maxOut)
            )
        }
        return out
    }

    private static func stepOnce(
        hidden: [String: [Double]],
        adjacency: [String: Set<String>],
        weights: MessagePassingWeights
    ) -> [String: [Double]] {
        // Aggregate mean of neighbour messages.
        var aggregated: [String: [Double]] = [:]
        aggregated.reserveCapacity(hidden.count)
        for (id, h) in hidden {
            let neighbours = adjacency[id] ?? []
            if neighbours.isEmpty {
                aggregated[id] = [Double](repeating: 0, count: h.count)
            } else {
                var acc = [Double](repeating: 0, count: h.count)
                for n in neighbours {
                    guard let nh = hidden[n] else { continue }
                    let msg = matVec(weights.message, nh)
                    for j in 0..<acc.count where j < msg.count { acc[j] += msg[j] }
                }
                let scale = 1.0 / Double(neighbours.count)
                for j in 0..<acc.count { acc[j] *= scale }
                aggregated[id] = acc
            }
        }
        // Concatenate [h_i ; agg_i], apply U, tanh.
        var next: [String: [Double]] = [:]
        next.reserveCapacity(hidden.count)
        for (id, h) in hidden {
            let agg = aggregated[id] ?? [Double](repeating: 0, count: h.count)
            let concat = h + agg
            let updated = matVec(weights.update, concat).map { tanh($0) }
            next[id] = updated
        }
        return next
    }

    private static func readout(_ h: [Double], weights w: [Double]) -> Double {
        var s = 0.0
        for (v, k) in zip(h, w) { s += v * k }
        return s
    }

    private static func matVec(_ m: [[Double]], _ v: [Double]) -> [Double] {
        m.map { row in
            var s = 0.0
            for i in 0..<min(row.count, v.count) { s += row[i] * v[i] }
            return s
        }
    }

    /// Topological sort stabilised by GNN score. When multiple nodes
    /// become ready simultaneously, the one with the higher score is
    /// placed first; GNN-score ties fall back to backlog position so
    /// user-visible drag order survives the warm-start seed instead of
    /// collapsing to whatever iteration order `eventIds` happens to have.
    private static func topologicalOrder(
        eventIds: [String],
        directPrecedes: [String: Set<String>],
        scores: [String: Double],
        backlogIndex: [String: Int]
    ) -> [String] {
        // Build inverse adjacency: what each node depends on.
        var inDegree: [String: Int] = Dictionary(uniqueKeysWithValues: eventIds.map { ($0, 0) })
        for (_, deps) in directPrecedes {
            for d in deps {
                inDegree[d, default: 0] += 1
            }
        }
        // Precedence predicate: strict > on GNN score, ties break by
        // earlier backlog position. Missing backlog indices sort last so
        // calendar-derived nodes never jump ahead of tagged backlog tasks.
        func precedes(_ lhs: String, _ rhs: String) -> Bool {
            let sl = scores[lhs] ?? 0
            let sr = scores[rhs] ?? 0
            if sl != sr { return sl > sr }
            let il = backlogIndex[lhs] ?? Int.max
            let ir = backlogIndex[rhs] ?? Int.max
            return il < ir
        }
        var ready = eventIds.filter { (inDegree[$0] ?? 0) == 0 }
        ready.sort(by: precedes)
        var ordered: [String] = []
        ordered.reserveCapacity(eventIds.count)
        while !ready.isEmpty {
            let id = ready.removeFirst()
            ordered.append(id)
            for next in directPrecedes[id] ?? [] {
                if var deg = inDegree[next] {
                    deg -= 1
                    inDegree[next] = deg
                    if deg == 0 {
                        let insertAt = ready.firstIndex { precedes(next, $0) } ?? ready.count
                        ready.insert(next, at: insertAt)
                    }
                }
            }
        }
        // Cycle / unreachable fallback: append remaining in original order.
        if ordered.count < eventIds.count {
            let placed = Set(ordered)
            ordered.append(contentsOf: eventIds.filter { !placed.contains($0) })
        }
        return ordered
    }

    /// Build features for a single chromosome — exposed so the
    /// trainer can credit-assign by gene without redoing graph work.
    public static func featuresFor(
        context: OptimizerContext
    ) -> [String: GNNNodeFeatures] {
        let graph = context.ensureConflictGraph()
        return buildFeatures(context: context, graph: graph)
    }

    /// Greedy slot-by-slot placement respecting `orderedIds`.
    private static func greedyAssign(
        orderedIds: [String],
        context: OptimizerContext
    ) -> ScheduleChromosome {
        let cal = context.calendar
        let horizonStart = cal.startOfDay(for: context.planningHorizon.start)
        let horizonEnd = context.planningHorizon.end
        let slotRegistry = context.ensureSlotRegistry()
        var cursor = horizonStart
        // Clamp cursor to working-hours start on horizon's first day.
        if let s = cal.date(bySettingHour: context.workingHours.lowerBound,
                            minute: 0, second: 0, of: cursor) {
            cursor = s
        }
        let eventMap: [String: OptimizableEvent] = Dictionary(
            uniqueKeysWithValues: context.movableEvents.map { ($0.id, $0) }
        )
        var genes: [ScheduleGene] = []
        genes.reserveCapacity(orderedIds.count)
        let workEnd = context.workingHours.upperBound
        for id in orderedIds {
            guard let event = eventMap[id] else { continue }
            var start = cursor
            while start < horizonEnd {
                let hour = cal.component(.hour, from: start)
                let end = start.addingTimeInterval(event.duration)
                let endHour = cal.component(.hour, from: end)
                if hour >= context.workingHours.lowerBound
                    && endHour <= workEnd
                    && end <= horizonEnd {
                    break
                }
                // Skip to next day's working-hour start.
                guard let nextDay = cal.date(byAdding: .day, value: 1, to: start) else {
                    break
                }
                let nextStart = cal.startOfDay(for: nextDay)
                start = cal.date(
                    bySettingHour: context.workingHours.lowerBound,
                    minute: 0, second: 0, of: nextStart
                ) ?? nextStart
            }
            if start >= horizonEnd { continue }
            // Align seed to the registry grid so `startTime` stays
            // kept with `slotIndex` — otherwise the day-rollover math
            // above can leave sub-minute drift on days where horizon
            // edges don't fall on grid boundaries.
            let boundSlot = slotRegistry.nearestIndex(to: start)
            let alignedStart = boundSlot.flatMap { slotRegistry.resolvedDate(at: $0) } ?? start
            let gene = ScheduleGene(
                eventId: event.id,
                title: event.title,
                startTime: alignedStart,
                duration: event.duration,
                context: event.context,
                energyCost: event.energyCost,
                priority: event.priority,
                isFocusBlock: event.isFocusBlock,
                storyPoints: event.storyPoints,
                isDroppable: event.isDroppable,
                isIncluded: true,
                pomodoroConfig: event.pomodoroConfig,
                reservedTaskIds: event.reservedTaskIds,
                slotIndex: boundSlot
            )
            genes.append(gene)
            cursor = gene.endTime
        }
        var chromo = ScheduleChromosome(genes: genes, needsEvaluation: true)
        chromo.repair(context: context)
        return chromo
    }
}
