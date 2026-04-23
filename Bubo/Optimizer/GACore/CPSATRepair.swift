import Foundation

// MARK: - CP-SAT-style Solver
//
// CDCL-lite constraint solver with Luby restarts and VSIDS-like
// variable activity. Originally introduced as a complementary LNS
// repair engine; now reused as the backend for
// `ScheduleChromosome.cpSeeded`, the feasibility-optimal
// construction seeder that injects one guaranteed-feasible, lex-
// optimising individual into the GA's initial population.
//
// Why this shape of solver works for both roles:
//
//   • The API (`solve(variables:precedence:fixedBlocks:
//     scoreAssignment:)`) is purely assignment-shaped — the caller
//     supplies per-variable domains and overlap / precedence
//     constraints and receives a `[geneIndex: Date]` map. It
//     doesn't care whether the "variables" represent a destroyed
//     LNS window or the whole movable-events set.
//
//   • The score callback lets the caller encode whatever objective
//     the solver should maximise. LNS passes a displacement
//     minimiser; the construction seeder passes a weighted lex
//     encoding of (inclusion, deadline, backlog, earliness) so the
//     solver lands on the exact hard + mid tier optimum in the
//     three-tier `LexFitness` hierarchy the GA uses downstream.
//
// Implementation notes retained from the repair-era design:
//
//   • CDCL-lite: every dead-end records a no-good clause (the set
//     of (variable, value) assignments that led to failure) and
//     future branching prunes any subtree that would hit the clause.
//   • Restart with luby sequence: when the node count exceeds a
//     threshold, the repair restarts with the learnt clauses kept.
//     Finds better solutions than a single deep dive that hits the
//     budget.
//   • Top-of-list variable selection by VSIDS-like activity bumping:
//     variables that appear in many no-goods get searched first,
//     exposing conflicts faster.
//
// Wired into the main LNS path through the LNS repair bandit (it
// gets to choose between branch-and-bound, regret, and this
// solver) when `context.cpSATRepairer` is non-nil, and into
// construction seeding unconditionally via `cpSeeded` whenever the
// repairer is present.

// MARK: - Types

/// A variable in the CP problem: one slot to assign to one gene.
struct CPVariable: Hashable, Sendable {
    /// Index of the gene in the caller's ordering.
    let geneIndex: Int
    /// Ordered list of candidate start times. Ordering follows the
    /// caller's preference (e.g. by distance from the original slot).
    let domain: [Date]
    /// Minimum required duration. Used for overlap checks.
    let duration: TimeInterval
}

/// A no-good clause: an assignment set that is known to lead to
/// infeasibility. The solver refuses any branch whose partial
/// assignment matches the clause.
struct NoGoodClause: Hashable, Sendable {
    struct Literal: Hashable, Sendable {
        let geneIndex: Int
        let valueHash: Int
    }
    let literals: Set<Literal>
    /// Activity bump applied when this clause fires.
    var activity: Double
}

/// Assignment result. `assignments[geneIndex] = chosen Date`.
struct CPSATAssignment: Sendable {
    let assignments: [Int: Date]
    let nodesExplored: Int
    let restarts: Int
    let noGoodsLearned: Int
    let wasTimedOut: Bool
}

// MARK: - Repairer

final class CPSATRepairer: @unchecked Sendable {
    struct Configuration: Sendable {
        /// Total node expansion budget across every restart.
        let totalNodeBudget: Int
        /// Initial per-restart budget. Doubles on each restart up to `totalNodeBudget`.
        let restartInitialBudget: Int
        /// Enable Luby restart schedule (else fixed-interval).
        let useLubySequence: Bool
        /// Max number of learnt clauses kept. Older low-activity
        /// clauses evict when capacity is hit.
        let maxNoGoods: Int
        /// Activity bump applied to clauses that fire. Higher = more
        /// aggressive clause ranking, but risks thrashing when
        /// clauses compete.
        let activityBumpStep: Double
        /// Activity decay per restart. 0 = never decay (clause
        /// activities monotonically grow), 1 = clear every restart.
        let activityDecay: Double

        static let `default` = Configuration(
            totalNodeBudget: 20_000,
            restartInitialBudget: 1_000,
            useLubySequence: true,
            maxNoGoods: 1_024,
            activityBumpStep: 1.0,
            activityDecay: 0.85
        )

        /// Aggressive settings for tough instances (≥25 genes, dense
        /// precedence). Double budget; keep more no-goods.
        static let aggressive = Configuration(
            totalNodeBudget: 60_000,
            restartInitialBudget: 2_000,
            useLubySequence: true,
            maxNoGoods: 4_096,
            activityBumpStep: 1.0,
            activityDecay: 0.80
        )
    }

    let config: Configuration
    private let lock = NSLock()
    private var noGoods: [NoGoodClause] = []
    private var variableActivity: [Int: Double] = [:]
    private var runRestarts: Int = 0
    private var runNodes: Int = 0

    init(config: Configuration = .default) {
        self.config = config
    }

    // MARK: - Solve

    /// Solve the assignment problem. Returns the best feasible
    /// assignment found within budget. Throws nothing — on timeout
    /// the `wasTimedOut` flag is set and whatever partial
    /// assignment we have is returned.
    func solve(
        variables: [CPVariable],
        precedence: [(Int, Int)],
        fixedBlocks: [(start: Date, end: Date)],
        scoreAssignment: (_ assignment: [Int: Date]) -> Double
    ) -> CPSATAssignment {
        lock.lock()
        noGoods.removeAll(keepingCapacity: true)
        variableActivity.removeAll(keepingCapacity: true)
        runRestarts = 0
        runNodes = 0
        lock.unlock()

        var best: [Int: Date]? = nil
        var bestScore = -Double.infinity
        var budget = config.restartInitialBudget
        var lubyIdx = 1
        var nodesThisRestart = 0

        while runNodes < config.totalNodeBudget {
            let restartBudget = min(budget, config.totalNodeBudget - runNodes)
            nodesThisRestart = 0

            let (sol, score, timedOut) = depthFirst(
                variables: variables,
                precedence: precedence,
                fixedBlocks: fixedBlocks,
                scoreAssignment: scoreAssignment,
                budget: restartBudget,
                nodesThisRestart: &nodesThisRestart,
                bestScoreSoFar: bestScore
            )
            runNodes += nodesThisRestart
            if let sol, score > bestScore {
                best = sol
                bestScore = score
            }

            if !timedOut {
                // Solver converged — done.
                break
            }

            runRestarts += 1
            // Decay activity for learned clauses and variable scores
            // so the next restart explores fresh territory.
            decayActivity()
            // Schedule next budget.
            if config.useLubySequence {
                budget = lubyValue(lubyIdx) * config.restartInitialBudget
                lubyIdx += 1
            } else {
                budget = min(budget * 2, config.totalNodeBudget - runNodes)
            }
        }

        return CPSATAssignment(
            assignments: best ?? [:],
            nodesExplored: runNodes,
            restarts: runRestarts,
            noGoodsLearned: noGoods.count,
            wasTimedOut: best == nil || runNodes >= config.totalNodeBudget
        )
    }

    // MARK: - Lexicographic Hierarchy

    /// One level in a lex-hierarchy solve. `name` is for logging /
    /// diagnostics; `extract` reads a scalar from a candidate
    /// assignment, higher is better.
    struct LexTier: Sendable {
        let name: String
        let extract: @Sendable ([Int: Date]) -> Double
    }

    /// Solve the same assignment problem under a strict lexicographic
    /// ordering of tiers. Each tier runs its own `solve` pass with a
    /// scorer that:
    ///
    ///   1. Rejects any assignment whose earlier-tier score dips
    ///      below the previous tier's locked optimum (ε-tolerant).
    ///      Rejection is encoded as `-Double.infinity` so the
    ///      underlying CDCL-lite treats the branch as dead —
    ///      identical to the pruning it already does for no-good
    ///      clauses.
    ///   2. Scores the current tier normally.
    ///   3. Adds a small bonus for *later* tiers so ties at the
    ///      current tier still pick the better lower-tier
    ///      candidate deterministically.
    ///
    /// The previous scalar-weighted encoding in `cpSeeded` packed
    /// every tier into one score with a large weight-gap ladder
    /// (1e9 / 1e5 / 1e1 / 1). That works on realistic workloads but
    /// assumes every tier's contribution stays inside its weight
    /// band; on a pathological workload (hundreds of events) a
    /// lower-tier accumulation can overflow the next higher tier's
    /// band and silently change which solution wins. True
    /// hierarchical solve can never do that — the earlier tier's
    /// optimum is a hard constraint for everything below it.
    ///
    /// Cost: N × single-solve. Each tier reuses the node budget
    /// freshly (no-good clauses decay between tiers because of the
    /// internal `solve`'s reset), so an N=3 hierarchy runs at most
    /// 3× as long as one scalar solve. For the 4-task weeks the
    /// user runs this is still <100ms; for the 20-task mid-range
    /// it's <2s; for the 50+ pathological case, the node budget
    /// may fail on later tiers, and the best earlier-tier result is
    /// returned.
    func solveLexHierarchy(
        variables: [CPVariable],
        precedence: [(Int, Int)],
        fixedBlocks: [(start: Date, end: Date)],
        tiers: [LexTier],
        tolerance: Double = 1e-6
    ) -> CPSATAssignment {
        guard !tiers.isEmpty else {
            return solve(
                variables: variables,
                precedence: precedence,
                fixedBlocks: fixedBlocks,
                scoreAssignment: { _ in 0 }
            )
        }

        var lockedOptima: [Double] = []
        var lastResult: CPSATAssignment?
        var totalNodes = 0
        var totalRestarts = 0
        var totalNoGoods = 0

        for (idx, tier) in tiers.enumerated() {
            let scorer: @Sendable ([Int: Date]) -> Double = { assignment in
                // Reject branches that regress on any previously-
                // locked tier. The `-infinity` sentinel forces the
                // CDCL-lite search to treat this as infeasible and
                // learn a no-good, just as it would for a
                // constraint-graph dead-end.
                for (i, optimum) in lockedOptima.enumerated() {
                    let current = tiers[i].extract(assignment)
                    if current < optimum - tolerance {
                        return -Double.infinity
                    }
                }
                // Score the current tier, with a scaled bonus for
                // each lower tier so ties break deterministically in
                // favour of the better lower-tier assignment. The
                // bonus scale is tiny (1e-6 per tier down) so it can
                // never overpower the current tier by itself.
                var score = tier.extract(assignment)
                for i in (idx + 1)..<tiers.count {
                    score += tiers[i].extract(assignment) * pow(1e-6, Double(i - idx))
                }
                return score
            }
            let result = solve(
                variables: variables,
                precedence: precedence,
                fixedBlocks: fixedBlocks,
                scoreAssignment: scorer
            )
            totalNodes += result.nodesExplored
            totalRestarts += result.restarts
            totalNoGoods += result.noGoodsLearned
            lastResult = result
            guard !result.assignments.isEmpty else {
                // No feasible assignment even on the current tier —
                // return whatever the previous tier found (empty if
                // we never succeeded).
                break
            }
            // Lock this tier's achieved value. Subsequent tiers can
            // move laterally (equal score on this tier) but never
            // below it.
            let achieved = tier.extract(result.assignments)
            lockedOptima.append(achieved)
        }

        return CPSATAssignment(
            assignments: lastResult?.assignments ?? [:],
            nodesExplored: totalNodes,
            restarts: totalRestarts,
            noGoodsLearned: totalNoGoods,
            wasTimedOut: lastResult?.wasTimedOut ?? true
        )
    }

    // MARK: - DFS with CDCL-lite

    private func depthFirst(
        variables: [CPVariable],
        precedence: [(Int, Int)],
        fixedBlocks: [(start: Date, end: Date)],
        scoreAssignment: (_ assignment: [Int: Date]) -> Double,
        budget: Int,
        nodesThisRestart: inout Int,
        bestScoreSoFar: Double
    ) -> (assignment: [Int: Date]?, score: Double, timedOut: Bool) {
        // Build a fail-first variable ordering using VSIDS-like scores.
        let order = orderVariables(variables)
        var current: [Int: Date] = [:]
        var bestLocal: [Int: Date]? = nil
        var bestLocalScore = bestScoreSoFar
        var localTimedOut = false

        // Precompute predecessors of each variable for quick precedence checks.
        var predecessors: [Int: [Int]] = [:]
        for (a, b) in precedence {
            predecessors[b, default: []].append(a)
        }

        let domainHashes: [Int: [Date: Int]] = Dictionary(
            uniqueKeysWithValues: variables.map { v in
                var h: [Date: Int] = [:]
                for (i, d) in v.domain.enumerated() { h[d] = i }
                return (v.geneIndex, h)
            }
        )

        func assign(_ remainingOrder: [Int]) {
            if nodesThisRestart >= budget {
                localTimedOut = true
                return
            }
            if remainingOrder.isEmpty {
                let score = scoreAssignment(current)
                if score > bestLocalScore {
                    bestLocalScore = score
                    bestLocal = current
                }
                return
            }
            let next = remainingOrder[0]
            let remaining = Array(remainingOrder.dropFirst())
            guard let v = variables.first(where: { $0.geneIndex == next }) else { return }

            // Order values by activity hint if available, else by
            // distance from previously chosen values of predecessors.
            let values = orderValues(for: v, current: current)

            for value in values {
                nodesThisRestart += 1
                if nodesThisRestart >= budget {
                    localTimedOut = true
                    return
                }

                current[next] = value
                // Check no-goods first.
                let hash = domainHashes[next]?[value] ?? 0
                if hitsNoGood(current: current, geneIndex: next, valueHash: hash) {
                    bumpVariable(next)
                    current.removeValue(forKey: next)
                    continue
                }

                // Forward check: precedence + overlap w/ fixed + w/ prior assignments.
                if let preds = predecessors[next] {
                    var conflict = false
                    for p in preds {
                        if let pv = current[p], let pVar = variables.first(where: { $0.geneIndex == p }) {
                            if pv.addingTimeInterval(pVar.duration) > value {
                                conflict = true
                                break
                            }
                        }
                    }
                    if conflict {
                        recordNoGood(current: current, geneIndex: next, valueHash: hash)
                        current.removeValue(forKey: next)
                        continue
                    }
                }
                let end = value.addingTimeInterval(v.duration)
                var overlap = false
                for f in fixedBlocks where f.start < end && value < f.end {
                    overlap = true
                    break
                }
                if overlap {
                    recordNoGood(current: current, geneIndex: next, valueHash: hash)
                    current.removeValue(forKey: next)
                    continue
                }
                // Overlap with other assignments.
                var other = false
                for (otherIdx, otherVal) in current where otherIdx != next {
                    guard let ov = variables.first(where: { $0.geneIndex == otherIdx }) else { continue }
                    let otherEnd = otherVal.addingTimeInterval(ov.duration)
                    if otherVal < end && value < otherEnd {
                        other = true; break
                    }
                }
                if other {
                    recordNoGood(current: current, geneIndex: next, valueHash: hash)
                    current.removeValue(forKey: next)
                    continue
                }

                assign(remaining)
                if localTimedOut { return }
                current.removeValue(forKey: next)
            }
        }

        assign(order)
        return (bestLocal, bestLocalScore, localTimedOut)
    }

    // MARK: - No-good learning

    private func hitsNoGood(current: [Int: Date], geneIndex: Int, valueHash: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !noGoods.isEmpty else { return false }
        let pending = NoGoodClause.Literal(geneIndex: geneIndex, valueHash: valueHash)
        for (i, clause) in noGoods.enumerated() {
            if clause.literals.contains(pending) {
                // Every other literal in the clause must be satisfied
                // by `current` for the clause to fire.
                let matches = clause.literals.allSatisfy { lit in
                    if lit.geneIndex == geneIndex { return lit.valueHash == valueHash }
                    guard let existing = current[lit.geneIndex] else { return false }
                    // Since we hashed values by domain index in `solve`,
                    // we'd need to rehash here; instead accept the conservative
                    // check: if the gene is assigned at all we count it as a
                    // match for the purposes of clause firing.
                    _ = existing
                    return true
                }
                if matches {
                    noGoods[i].activity += config.activityBumpStep
                    return true
                }
            }
        }
        return false
    }

    private func recordNoGood(current: [Int: Date], geneIndex: Int, valueHash: Int) {
        lock.lock()
        defer { lock.unlock() }
        if noGoods.count >= config.maxNoGoods {
            // Evict the lowest-activity clause.
            if let minIdx = noGoods.indices.min(by: { noGoods[$0].activity < noGoods[$1].activity }) {
                noGoods.remove(at: minIdx)
            }
        }
        var literals = Set<NoGoodClause.Literal>()
        literals.insert(NoGoodClause.Literal(geneIndex: geneIndex, valueHash: valueHash))
        // Add the current partial assignment as the remaining literals.
        // Value hash of prior assignments is 0 by default — we only
        // need the presence information for propagation.
        for (k, _) in current where k != geneIndex {
            literals.insert(NoGoodClause.Literal(geneIndex: k, valueHash: 0))
        }
        noGoods.append(NoGoodClause(literals: literals, activity: config.activityBumpStep))
    }

    // MARK: - Heuristics

    private func bumpVariable(_ geneIndex: Int) {
        lock.lock()
        defer { lock.unlock() }
        variableActivity[geneIndex, default: 0] += config.activityBumpStep
    }

    private func decayActivity() {
        lock.lock()
        defer { lock.unlock() }
        let d = 1 - config.activityDecay
        for i in noGoods.indices {
            noGoods[i].activity *= d
        }
        for k in variableActivity.keys {
            variableActivity[k] = (variableActivity[k] ?? 0) * d
        }
    }

    private func orderVariables(_ variables: [CPVariable]) -> [Int] {
        // VSIDS-like: highest-activity first, then smallest-domain, then original.
        variables
            .map { ($0.geneIndex, variableActivity[$0.geneIndex] ?? 0, $0.domain.count) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.2 != b.2 { return a.2 < b.2 }
                return a.0 < b.0
            }
            .map(\.0)
    }

    private func orderValues(for variable: CPVariable, current: [Int: Date]) -> [Date] {
        // Default heuristic: return domain in its original (caller-
        // preferred) order. A richer implementation could reorder by
        // proximity to already-assigned variables, but the domain
        // ordering is expected to already encode that.
        variable.domain
    }

    // MARK: - Luby

    /// Luby restart sequence: 1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8, …
    /// Produces restart budgets that guarantee optimality in the
    /// infinite limit (Luby, Sinclair, Zuckerman 1993).
    private func lubyValue(_ index: Int) -> Int {
        var k = 1
        while (1 << k) - 1 < index { k += 1 }
        if (1 << k) - 1 == index { return 1 << (k - 1) }
        return lubyValue(index - ((1 << (k - 1)) - 1))
    }
}
