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

        public let geneIndex: Int
        public let valueHash: Int
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

