import Foundation

// MARK: - Chromosome Protocol

/// A generic chromosome for the genetic algorithm.
///
/// Hashable conformance is required so the GA can detect duplicate individuals
/// in O(N) via a Set lookup rather than O(N²) via pairwise Equatable. Every
/// concrete chromosome in this codebase already has Hashable-ready fields
/// (genes, sequence, …) so implementing `hash(into:)` is a one-liner.
public protocol Chromosome: Hashable {
    public var fitness: Double { get set }

    /// Raw fitness before any diversity adjustments (fitness sharing, niching).
    /// Equals `fitness` unless fitness sharing has reduced the visible fitness
    /// for selection pressure. `bestEver` tracking must use `rawFitness` so that
    /// a globally-best-but-crowded individual isn't lost to a sharing-penalized score.
    public var rawFitness: Double { get set }

    /// Create a random chromosome within the given context.
    public static func random(context: OptimizerContext) -> Self

    /// Create a heuristically-seeded chromosome using greedy placement.
    /// Returns a feasible (or near-feasible) starting point for the GA.
    public static func greedy(context: OptimizerContext) -> Self

    /// Create a heuristically-seeded chromosome using an alternative
    /// greedy ordering, indexed by `variantIndex`. Different indices
    /// should exercise qualitatively different insertion orders
    /// (priority-first, deadline-first, duration-first, …) so
    /// multi-seed populations actually explore multiple basins
    /// instead of starting as `N` identical copies of the default
    /// greedy. Default implementation falls back to `greedy` for
    /// chromosome types that don't benefit from variant seeding.
    public static func greedy(context: OptimizerContext, variantIndex: Int) -> Self

    /// Produce two offspring via crossover with another chromosome.
    public func crossover(with other: Self, context: OptimizerContext) -> (Self, Self)

    /// Produce two offspring via crossover using a specific strategy.
    public func crossover(with other: Self, strategy: CrossoverStrategy, context: OptimizerContext) -> (Self, Self)

    /// Apply random mutations at the given rate.
    public mutating func mutate(rate: Double, context: OptimizerContext)

    /// Repair constraint violations in-place (e.g. fix overlaps, clamp to working hours).
    public mutating func repair(context: OptimizerContext)

    /// Genotypic distance to another chromosome, normalized to [0, 1].
    /// Used for diversity measurement, crowding, and fitness sharing.
    public func distance(to other: Self) -> Double
}

public extension Chromosome {
    /// Default: ignore strategy, fall back to the basic crossover.
    public func crossover(with other: Self, strategy: CrossoverStrategy, context: OptimizerContext) -> (Self, Self) {
        crossover(with: other, context: context)
    }

    /// Default no-op repair for chromosomes without constraint awareness.
    public mutating func repair(context: OptimizerContext) {}

    /// Default greedy falls back to random.
    public static func greedy(context: OptimizerContext) -> Self {
        random(context: context)
    }

    /// Default variant-greedy ignores the variant index. Concrete
    /// types that want multi-strategy seeding override this.
    public static func greedy(context: OptimizerContext, variantIndex: Int) -> Self {
        greedy(context: context)
    }

    /// Default distance: 0 if equal, 1 otherwise.
    public func distance(to other: Self) -> Double {
        self == other ? 0 : 1
    }
}

