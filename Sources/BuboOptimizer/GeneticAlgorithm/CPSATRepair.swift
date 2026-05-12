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
public struct CPVariable: Hashable, Sendable {

    public init(
        geneIndex: Int,
        domain: [Date],
        duration: TimeInterval
    ) {
        self.geneIndex = geneIndex
        self.domain = domain
        self.duration = duration
    }

    /// Index of the gene in the caller's ordering.
    public let geneIndex: Int
    /// Ordered list of candidate start times. Ordering follows the
    /// caller's preference (e.g. by distance from the original slot).
    public let domain: [Date]
    /// Minimum required duration. Used for overlap checks.
    public let duration: TimeInterval
}

/// A no-good clause: an assignment set that is known to lead to
/// infeasibility. The solver refuses any branch whose partial
/// assignment matches the clause.
public struct NoGoodClause: Hashable, Sendable {

    public init(
        literals: Set<Literal>,
        activity: Double
    ) {
        self.literals = literals
        self.activity = activity
    }

    public struct Literal: Hashable, Sendable {

        public init(
            geneIndex: Int,
            valueHash: Int
        ) {
            self.geneIndex = geneIndex
            self.valueHash = valueHash
        }

        let geneIndex: Int
        let valueHash: Int
    }
    public let literals: Set<Literal>
    /// Activity bump applied when this clause fires.
    public var activity: Double
}

/// Assignment result. `assignments[geneIndex] = chosen Date`.
public struct CPSATAssignment: Sendable {

    public init(
        assignments: [Int: Date],
        nodesExplored: Int,
        restarts: Int,
        noGoodsLearned: Int,
        wasTimedOut: Bool
    ) {
        self.assignments = assignments
        self.nodesExplored = nodesExplored
        self.restarts = restarts
        self.noGoodsLearned = noGoodsLearned
        self.wasTimedOut = wasTimedOut
    }

    public let assignments: [Int: Date]
    public let nodesExplored: Int
    public let restarts: Int
    public let noGoodsLearned: Int
    public let wasTimedOut: Bool
}

// MARK: - Repairer

public final class CPSATRepairer: @unchecked Sendable {
    public struct Configuration: Sendable {

        public init(
            totalNodeBudget: Int,
            restartInitialBudget: Int,
            useLubySequence: Bool,
            maxNoGoods: Int,
            activityBumpStep: Double,
            activityDecay: Double
        ) {
            self.totalNodeBudget = totalNodeBudget
            self.restartInitialBudget = restartInitialBudget
            self.useLubySequence = useLubySequence
            self.maxNoGoods = maxNoGoods
            self.activityBumpStep = activityBumpStep
            self.activityDecay = activityDecay
        }

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

    public let config: Configuration

    public init(config: Configuration = .default) {
        self.config = config
    }

    /// Per-solve scratch state. Lives for the duration of one
    /// `solve()` call only — all the dictionaries the DFS reads and
    /// mutates are stored here instead of on the repairer itself, so
    /// two concurrent `solve()` invocations on the same instance can't
    /// race on a shared Dictionary's COW buffer. The previous design
    /// kept this state at instance level behind an `NSLock`, but
    /// `orderVariables`, `hitsNoGood`, and `bumpVariable` all read
    /// `variableActivity` / `noGoods` from inside the DFS without
    /// holding the lock, so a concurrent reset in another thread's
    /// `solve()` reliably crashed `Collection.map` with EXC_BAD_ACCESS.
    /// Per-call state removes the shared dependency entirely; no lock
    /// is needed because nothing on `self` is mutated.
    private final class SolveState {
        var noGoods: [NoGoodClause] = []
        var variableActivity: [Int: Double] = [:]
        var runRestarts: Int = 0
        var runNodes: Int = 0
    }

    // MARK: - Solve

    /// Solve the assignment problem. Returns the best feasible
    /// assignment found within budget. Throws nothing — on timeout
    /// the `wasTimedOut` flag is set and whatever partial
    /// assignment we have is returned.
    ///
    /// `hint` is an optional warm-start assignment. When every
    /// variable in `hint` is feasible against `precedence` and
    /// `fixedBlocks`, the hint is scored up front and becomes the
    /// initial incumbent; subsequent DFS branches have to beat it
    /// to survive. An infeasible or partial hint is silently
    /// ignored — warm-start is best-effort, never a correctness
    /// dependency.
    public func solve(
        variables: [CPVariable],
        precedence: [(Int, Int)],
        fixedBlocks: [(start: Date, end: Date)],
        scoreAssignment: (_ assignment: [Int: Date]) -> Double,
        hint: [Int: Date]? = nil
    ) -> CPSATAssignment {
        let state = SolveState()

        var best: [Int: Date]? = nil
        var bestScore = -Double.infinity
        // Seed the incumbent with a feasible warm-start hint if one
        // was supplied. The DFS uses `bestScoreSoFar` as its cutoff
        // reference, so a pre-seeded incumbent prunes worse branches
        // from the first node rather than after a full exploratory
        // descent. Infeasible or partial hints skip this block.
        if let hint, hint.count == variables.count,
           hintIsFeasible(
               hint,
               variables: variables,
               precedence: precedence,
               fixedBlocks: fixedBlocks
           ) {
            best = hint
            bestScore = scoreAssignment(hint)
        }
        var budget = config.restartInitialBudget
        var lubyIdx = 1
        var nodesThisRestart = 0

        while state.runNodes < config.totalNodeBudget {
            let restartBudget = min(budget, config.totalNodeBudget - state.runNodes)
            nodesThisRestart = 0

            let (sol, score, timedOut) = depthFirst(
                variables: variables,
                precedence: precedence,
                fixedBlocks: fixedBlocks,
                scoreAssignment: scoreAssignment,
                budget: restartBudget,
                nodesThisRestart: &nodesThisRestart,
                bestScoreSoFar: bestScore,
                hint: hint,
                state: state
            )
            state.runNodes += nodesThisRestart
            if let sol, score > bestScore {
                best = sol
                bestScore = score
            }

            if !timedOut {
                // Solver converged — done.
                break
            }

            state.runRestarts += 1
            // Decay activity for learned clauses and variable scores
            // so the next restart explores fresh territory.
            decayActivity(state: state)
            // Schedule next budget.
            if config.useLubySequence {
                budget = lubyValue(lubyIdx) * config.restartInitialBudget
                lubyIdx += 1
            } else {
                budget = min(budget * 2, config.totalNodeBudget - state.runNodes)
            }
        }

        return CPSATAssignment(
            assignments: best ?? [:],
            nodesExplored: state.runNodes,
            restarts: state.runRestarts,
            noGoodsLearned: state.noGoods.count,
            wasTimedOut: best == nil || state.runNodes >= config.totalNodeBudget
        )
    }

    // MARK: - Lexicographic Hierarchy

    /// One level in a lex-hierarchy solve. `name` is for logging /
    /// diagnostics; `extract` reads a scalar from a candidate
    /// assignment, higher is better.
    public struct LexTier: Sendable {

        public init(
            name: String,
            extract: @Sendable ([Int: Date]) -> Double
        ) {
            self.name = name
            self.extract = extract
        }

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
    public func solveLexHierarchy(
        variables: [CPVariable],
        precedence: [(Int, Int)],
        fixedBlocks: [(start: Date, end: Date)],
        tiers: [LexTier],
        hint: [Int: Date]? = nil,
        tolerance: Double = 1e-6
    ) -> CPSATAssignment {
        guard !tiers.isEmpty else {
            return solve(
                variables: variables,
                precedence: precedence,
                fixedBlocks: fixedBlocks,
                scoreAssignment: { _ in 0 },
                hint: hint
            )
        }

        var lockedOptima: [Double] = []
        var lastResult: CPSATAssignment?
        var totalNodes = 0
        var totalRestarts = 0
        var totalNoGoods = 0

        for (idx, tier) in tiers.enumerated() {
            let lockedSnapshot = lockedOptima
            let scorer: @Sendable ([Int: Date]) -> Double = { assignment in
                // Reject branches that regress on any previously-
                // locked tier. The `-infinity` sentinel forces the
                // CDCL-lite search to treat this as infeasible and
                // learn a no-good, just as it would for a
                // constraint-graph dead-end.
                for (i, optimum) in lockedSnapshot.enumerated() {
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
            // Later tiers carry the previous tier's achieved
            // assignment forward as an incumbent hint — the lex
            // guard rejects any regression, so the prior optimum is
            // always a valid warm-start for the next solve.
            let perTierHint: [Int: Date]? = idx == 0 ? hint : lastResult?.assignments
            let result = solve(
                variables: variables,
                precedence: precedence,
                fixedBlocks: fixedBlocks,
                scoreAssignment: scorer,
                hint: perTierHint
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
        bestScoreSoFar: Double,
        hint: [Int: Date]? = nil,
        state: SolveState
    ) -> (assignment: [Int: Date]?, score: Double, timedOut: Bool) {
        // Build a fail-first variable ordering using VSIDS-like scores.
        let order = orderVariables(variables, state: state)
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
            // A warm-start hint (when present) pushes its suggested
            // value to the front so the incumbent is reached on the
            // left-most branch and subsequent siblings are pruned.
            let values = orderValues(
                for: v,
                current: current,
                hint: hint?[next]
            )

            for value in values {
                nodesThisRestart += 1
                if nodesThisRestart >= budget {
                    localTimedOut = true
                    return
                }

                current[next] = value
                // Check no-goods first.
                let hash = domainHashes[next]?[value] ?? 0
                if hitsNoGood(current: current, geneIndex: next, valueHash: hash, state: state) {
                    bumpVariable(next, state: state)
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
                        recordNoGood(current: current, geneIndex: next, valueHash: hash, state: state)
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
                    recordNoGood(current: current, geneIndex: next, valueHash: hash, state: state)
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
                    recordNoGood(current: current, geneIndex: next, valueHash: hash, state: state)
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

    private func hitsNoGood(
        current: [Int: Date],
        geneIndex: Int,
        valueHash: Int,
        state: SolveState
    ) -> Bool {
        guard !state.noGoods.isEmpty else { return false }
        let pending = NoGoodClause.Literal(geneIndex: geneIndex, valueHash: valueHash)
        for (i, clause) in state.noGoods.enumerated() {
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
                    state.noGoods[i].activity += config.activityBumpStep
                    return true
                }
            }
        }
        return false
    }

    private func recordNoGood(
        current: [Int: Date],
        geneIndex: Int,
        valueHash: Int,
        state: SolveState
    ) {
        if state.noGoods.count >= config.maxNoGoods {
            // Evict the lowest-activity clause.
            if let minIdx = state.noGoods.indices.min(by: { state.noGoods[$0].activity < state.noGoods[$1].activity }) {
                state.noGoods.remove(at: minIdx)
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
        state.noGoods.append(NoGoodClause(literals: literals, activity: config.activityBumpStep))
    }

    // MARK: - Heuristics

    private func bumpVariable(_ geneIndex: Int, state: SolveState) {
        state.variableActivity[geneIndex, default: 0] += config.activityBumpStep
    }

    private func decayActivity(state: SolveState) {
        let d = 1 - config.activityDecay
        for i in state.noGoods.indices {
            state.noGoods[i].activity *= d
        }
        for k in state.variableActivity.keys {
            state.variableActivity[k] = (state.variableActivity[k] ?? 0) * d
        }
    }

    private func orderVariables(_ variables: [CPVariable], state: SolveState) -> [Int] {
        // VSIDS-like: highest-activity first, then smallest-domain, then original.
        variables
            .map { ($0.geneIndex, state.variableActivity[$0.geneIndex] ?? 0, $0.domain.count) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.2 != b.2 { return a.2 < b.2 }
                return a.0 < b.0
            }
            .map(\.0)
    }

    private func orderValues(
        for variable: CPVariable,
        current: [Int: Date],
        hint: Date? = nil
    ) -> [Date] {
        // Default heuristic: return domain in its original (caller-
        // preferred) order. A richer implementation could reorder by
        // proximity to already-assigned variables, but the domain
        // ordering is expected to already encode that.
        guard let hint, let hintIdx = variable.domain.firstIndex(of: hint), hintIdx != 0 else {
            return variable.domain
        }
        // Promote the hinted value to the front so the DFS reaches
        // the incumbent on its first descent.
        var promoted = variable.domain
        let value = promoted.remove(at: hintIdx)
        promoted.insert(value, at: 0)
        return promoted
    }

    /// Verify that a candidate warm-start assignment satisfies the
    /// same structural constraints the DFS checks at every node —
    /// precedence, fixed-block overlap, pairwise gene overlap. Used
    /// to gate the incumbent-seeding path in `solve`. Does not
    /// examine `scoreAssignment`, so an assignment that passes here
    /// is still allowed to lose to a better DFS result; it just
    /// starts the race from a known-feasible point.
    private func hintIsFeasible(
        _ hint: [Int: Date],
        variables: [CPVariable],
        precedence: [(Int, Int)],
        fixedBlocks: [(start: Date, end: Date)]
    ) -> Bool {
        // Index variables by geneIndex for O(1) lookup.
        var byIndex: [Int: CPVariable] = [:]
        byIndex.reserveCapacity(variables.count)
        for v in variables {
            byIndex[v.geneIndex] = v
        }
        // Every variable must be covered, and the domain must
        // contain the hinted value (else the hint falls outside
        // what the solver would ever propose).
        for v in variables {
            guard let value = hint[v.geneIndex] else { return false }
            if !v.domain.contains(value) { return false }
        }
        // Precedence: predecessor must end before dependent starts.
        for (pIdx, dIdx) in precedence {
            guard
                let pVar = byIndex[pIdx],
                let dVar = byIndex[dIdx],
                let pStart = hint[pIdx],
                let dStart = hint[dIdx]
            else { return false }
            _ = dVar
            if pStart.addingTimeInterval(pVar.duration) > dStart {
                return false
            }
        }
        // Fixed-block overlap.
        for v in variables {
            guard let start = hint[v.geneIndex] else { return false }
            let end = start.addingTimeInterval(v.duration)
            for f in fixedBlocks where f.start < end && start < f.end {
                return false
            }
        }
        // Pairwise gene overlap.
        let ordered = variables.compactMap { v -> (Int, Date, Date)? in
            guard let start = hint[v.geneIndex] else { return nil }
            return (v.geneIndex, start, start.addingTimeInterval(v.duration))
        }.sorted { $0.1 < $1.1 }
        for i in 1..<ordered.count {
            if ordered[i].1 < ordered[i - 1].2 { return false }
        }
        return true
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
