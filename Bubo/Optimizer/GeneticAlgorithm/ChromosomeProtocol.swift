import Foundation

// MARK: - Chromosome Protocol

/// A generic chromosome for the genetic algorithm.
///
/// Hashable conformance is required so the GA can detect duplicate individuals
/// in O(N) via a Set lookup rather than O(N²) via pairwise Equatable. Every
/// concrete chromosome in this codebase already has Hashable-ready fields
/// (genes, sequence, …) so implementing `hash(into:)` is a one-liner.
protocol Chromosome: Hashable {
    var fitness: Double { get set }

    /// Raw fitness before any diversity adjustments (fitness sharing, niching).
    /// Equals `fitness` unless fitness sharing has reduced the visible fitness
    /// for selection pressure. `bestEver` tracking must use `rawFitness` so that
    /// a globally-best-but-crowded individual isn't lost to a sharing-penalized score.
    var rawFitness: Double { get set }

    /// Create a random chromosome within the given context.
    static func random(context: OptimizerContext) -> Self

    /// Create a heuristically-seeded chromosome using greedy placement.
    /// Returns a feasible (or near-feasible) starting point for the GA.
    static func greedy(context: OptimizerContext) -> Self

    /// Create a heuristically-seeded chromosome using an alternative
    /// greedy ordering, indexed by `variantIndex`. Different indices
    /// should exercise qualitatively different insertion orders
    /// (priority-first, deadline-first, duration-first, …) so
    /// multi-seed populations actually explore multiple basins
    /// instead of starting as `N` identical copies of the default
    /// greedy. Default implementation falls back to `greedy` for
    /// chromosome types that don't benefit from variant seeding.
    static func greedy(context: OptimizerContext, variantIndex: Int) -> Self

    /// Produce two offspring via crossover with another chromosome.
    func crossover(with other: Self, context: OptimizerContext) -> (Self, Self)

    /// Produce two offspring via crossover using a specific strategy.
    func crossover(with other: Self, strategy: CrossoverStrategy, context: OptimizerContext) -> (Self, Self)

    /// Apply random mutations at the given rate.
    mutating func mutate(rate: Double, context: OptimizerContext)

    /// Repair constraint violations in-place (e.g. fix overlaps, clamp to working hours).
    mutating func repair(context: OptimizerContext)

    /// Genotypic distance to another chromosome, normalized to [0, 1].
    /// Used for diversity measurement, crowding, and fitness sharing.
    func distance(to other: Self) -> Double
}

extension Chromosome {
    /// Default: ignore strategy, fall back to the basic crossover.
    func crossover(with other: Self, strategy: CrossoverStrategy, context: OptimizerContext) -> (Self, Self) {
        crossover(with: other, context: context)
    }

    /// Default no-op repair for chromosomes without constraint awareness.
    mutating func repair(context: OptimizerContext) {}

    /// Default greedy falls back to random.
    static func greedy(context: OptimizerContext) -> Self {
        random(context: context)
    }

    /// Default variant-greedy ignores the variant index. Concrete
    /// types that want multi-strategy seeding override this.
    static func greedy(context: OptimizerContext, variantIndex: Int) -> Self {
        greedy(context: context)
    }

    /// Default distance: 0 if equal, 1 otherwise.
    func distance(to other: Self) -> Double {
        self == other ? 0 : 1
    }
}

