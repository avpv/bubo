import Foundation

// MARK: - Crossover Strategy

public enum CrossoverStrategy: Sendable {
    case singlePoint
    case twoPoint
    case uniform(swapProbability: Double)

    /// Day-block crossover: genes that share a day in a parent are inherited
    /// together. Much more semantically meaningful than positional swaps for
    /// scheduling — "this morning's meeting bundle" stays intact rather than
    /// being split gene-by-gene. The per-day inheritance coin flip is
    /// independent for each day, so children still explore the combinatorial
    /// space of day-sized recombinations.
    case dayBlock

    /// Attention-weighted contextual crossover. Each gene's inheritance
    /// decision is driven by a `GeneAttentionHead` that scores parent
    /// placements using priority, deadline urgency, and structural fit.
    /// Delegates to `ContextualCrossover.perform`; the head is read
    /// unconditionally from `OptimizerContext.contextualCrossoverHead`.
    case contextual(temperature: Double)

    /// Graph-aware subtree crossover: inherits whole weakly-connected
    /// components of the `ScheduleConflictGraph` from one parent or the
    /// other. Keeps `dependsOn` chains and participant-coupled events
    /// together so the child doesn't need a heavy repair pass to
    /// reassemble a cut dependency. Falls back to day-block when no
    /// conflict graph is available so the strategy stays safe on
    /// contexts that predate the graph infrastructure.
    case graphSubtree
}

// MARK: - Crossover

/// Crossover operators for schedule chromosomes.
public enum Crossover {

    /// Perform crossover on two parents using the given strategy.
    public static func perform(
        _ parent1: ScheduleChromosome,
        _ parent2: ScheduleChromosome,
        strategy: CrossoverStrategy = .singlePoint,
        context: OptimizerContext
    ) -> (ScheduleChromosome, ScheduleChromosome) {
        switch strategy {
        case .singlePoint:
            return parent1.crossover(with: parent2, context: context)
        case .twoPoint:
            return twoPointCrossover(parent1, parent2, rng: context.rng)
        case .uniform(let prob):
            return uniformCrossover(parent1, parent2, swapProbability: prob, rng: context.rng)
        case .dayBlock:
            return dayBlockCrossover(parent1, parent2, context: context)
        case .contextual(let temperature):
            return ContextualCrossover.perform(
                parent1, parent2,
                context: context,
                head: context.contextualCrossoverHead,
                temperature: temperature
            )
        case .graphSubtree:
            return graphSubtreeCrossover(parent1, parent2, context: context)
        }
    }

    // MARK: - Graph-Aware Subtree Crossover

    /// Inherit whole weakly-connected components from one parent or
    /// the other. For each component the conflict graph exposes,
    /// flip a coin: child1 gets parent1's gene placements for that
    /// component iff the coin comes up heads, else it gets parent2's.
    /// child2 takes the complement. Genes not covered by the graph
    /// (empty graph, or singletons that the union-find left isolated)
    /// fall through to parent1's placement by default — identical to
    /// the uniform-base behaviour on those indices.
    ///
    /// Why this helps: positional crossover cuts arbitrarily through
    /// `dependsOn` chains — roughly half of offspring will violate
    /// precedence on the cut edge and spend the next repair/eval
    /// cycle shifting back toward one of the parents. Component-
    /// level inheritance moves the recombination unit from "one gene"
    /// to "one structural cluster", so constraint violations are
    /// restricted to cross-component interactions that the constraint
    /// engine already handles cheaply.
    private static func graphSubtreeCrossover(
        _ p1: ScheduleChromosome,
        _ p2: ScheduleChromosome,
        context: OptimizerContext
    ) -> (ScheduleChromosome, ScheduleChromosome) {
        guard p1.genes.count == p2.genes.count, p1.genes.count > 1 else {
            return (p1, p2)
        }

        let graph = context.ensureConflictGraph()
        // Degenerate graph → fall back to day-block, which is the
        // next-cheapest "structural" crossover.
        guard graph.componentCount > 1 else {
            return dayBlockCrossover(p1, p2, context: context)
        }

        let rng = context.rng

        // Coin per component: true = child1 inherits this component's
        // genes from parent2; child2 inherits the complement. Using
        // one coin per component keeps the expected Hamming distance
        // between children balanced at 0.5 × gene count in
        // expectation, matching uniform crossover's variance while
        // preserving structural integrity.
        var takeFromP2 = [Bool](repeating: false, count: graph.componentCount)
        for i in 0..<graph.componentCount {
            takeFromP2[i] = rng.bool(probability: 0.5)
        }

        var child1Genes = p1.genes
        var child2Genes = p2.genes

        // For components flagged "swap": child1 gets parent2's placement
        // and child2 gets parent1's. Components not flagged keep the
        // init defaults (child1 = p1, child2 = p2). This mirrors the
        // dayBlock pattern so the Pareto-paired invariant holds: every
        // time slot ends up in exactly one child.
        for i in p1.genes.indices {
            let eventId = p1.genes[i].eventId
            guard let componentId = graph.componentOf[eventId] else { continue }
            if takeFromP2[componentId] {
                // `withPlacement` carries both `startTime` and
                // `slotIndex` across so the child keeps the donor's
                // slot binding — `withStartTime` would invalidate
                // it, forcing repair to re-bind every gene on the
                // next generation. See the slot-decoder MARK in
                // Chromosome.swift for the invariant.
                child1Genes[i] = p1.genes[i].withPlacement(from: p2.genes[i])
                child2Genes[i] = p2.genes[i].withPlacement(from: p1.genes[i])
            }
        }

        return (
            ScheduleChromosome.makeChild(genes: child1Genes, parents: (p1, p2), rng: rng),
            ScheduleChromosome.makeChild(genes: child2Genes, parents: (p2, p1), rng: rng)
        )
    }

    // MARK: - Two-Point Crossover

    private static func twoPointCrossover(
        _ p1: ScheduleChromosome,
        _ p2: ScheduleChromosome,
        rng: GARandom
    ) -> (ScheduleChromosome, ScheduleChromosome) {
        guard p1.genes.count > 2, p1.genes.count == p2.genes.count else { return (p1, p2) }

        var point1 = rng.int(in: 0..<p1.genes.count)
        var point2 = rng.int(in: 0..<p1.genes.count)
        if point1 > point2 { swap(&point1, &point2) }

        var child1Genes = p1.genes
        var child2Genes = p2.genes

        for i in point1...point2 {
            // Swap time slots between parents
            child1Genes[i] = makeGene(from: p1.genes[i], withTimeOf: p2.genes[i])
            child2Genes[i] = makeGene(from: p2.genes[i], withTimeOf: p1.genes[i])
        }

        return (
            ScheduleChromosome.makeChild(genes: child1Genes, parents: (p1, p2), rng: rng),
            ScheduleChromosome.makeChild(genes: child2Genes, parents: (p2, p1), rng: rng)
        )
    }

    // MARK: - Uniform Crossover

    private static func uniformCrossover(
        _ p1: ScheduleChromosome,
        _ p2: ScheduleChromosome,
        swapProbability: Double,
        rng: GARandom
    ) -> (ScheduleChromosome, ScheduleChromosome) {
        guard p1.genes.count == p2.genes.count else { return (p1, p2) }
        var child1Genes = p1.genes
        var child2Genes = p2.genes

        for i in p1.genes.indices {
            if rng.bool(probability: swapProbability) {
                child1Genes[i] = makeGene(from: p1.genes[i], withTimeOf: p2.genes[i])
                child2Genes[i] = makeGene(from: p2.genes[i], withTimeOf: p1.genes[i])
            }
        }

        return (
            ScheduleChromosome.makeChild(genes: child1Genes, parents: (p1, p2), rng: rng),
            ScheduleChromosome.makeChild(genes: child2Genes, parents: (p2, p1), rng: rng)
        )
    }

    // MARK: - Day-Block Crossover

    /// For every distinct day either parent placed any gene on, flip a coin
    /// that decides whether child1 inherits that day's block from parent1 or
    /// parent2 (child2 takes the complement). "Inherit a day's block" means:
    /// every gene *currently placed on that day in the donor* keeps the
    /// donor's start time in the child. Genes whose day doesn't appear in the
    /// decision map fall through to parent1's default placement.
    ///
    /// Why this helps over positional crossover: a morning meeting bundle is
    /// a structure worth preserving; chopping it up by gene index (as single-
    /// and two-point do) mostly produces schedules that the constraint
    /// engine immediately repairs back toward one of the parents, wasting
    /// the crossover. Day-block crossover moves the recombination unit from
    /// "one gene" to "one day", which is the granularity users think in.
    private static func dayBlockCrossover(
        _ p1: ScheduleChromosome,
        _ p2: ScheduleChromosome,
        context: OptimizerContext
    ) -> (ScheduleChromosome, ScheduleChromosome) {
        guard p1.genes.count == p2.genes.count, p1.genes.count > 1 else {
            return (p1, p2)
        }
        let cal = context.calendar
        let rng = context.rng

        // Collect every day touched by either parent. Using a set here gives
        // deterministic inheritance decisions regardless of iteration order,
        // because we only need one coin per day and the key lookup is stable.
        var touchedDays: Set<Date> = []
        for gene in p1.genes where gene.isIncluded {
            touchedDays.insert(cal.startOfDay(for: gene.startTime))
        }
        for gene in p2.genes where gene.isIncluded {
            touchedDays.insert(cal.startOfDay(for: gene.startTime))
        }

        // Per-day inheritance decision for child1: true = take parent2's times
        // on genes whose parent1 placement lands on that day. Child2 takes
        // the complement; we only need one coin flip per day.
        var takeFromP2: [Date: Bool] = [:]
        takeFromP2.reserveCapacity(touchedDays.count)
        for day in touchedDays {
            takeFromP2[day] = rng.bool(probability: 0.5)
        }

        var child1Genes = p1.genes
        var child2Genes = p2.genes

        for i in p1.genes.indices {
            let p1Day = cal.startOfDay(for: p1.genes[i].startTime)
            if takeFromP2[p1Day] == true {
                // `withPlacement` carries both `startTime` and
                // `slotIndex` — keeps day-block crossover in sync
                // with the slot-decoder invariant.
                child1Genes[i] = p1.genes[i].withPlacement(from: p2.genes[i])
            }

            // Mirror for child2 using its own parent's grouping. Reading the
            // same day map — decision flipped — keeps the pair Pareto-paired
            // (nothing is discarded on both children simultaneously).
            let p2Day = cal.startOfDay(for: p2.genes[i].startTime)
            if takeFromP2[p2Day] == false {
                child2Genes[i] = p2.genes[i].withPlacement(from: p1.genes[i])
            }
        }

        return (
            ScheduleChromosome.makeChild(genes: child1Genes, parents: (p1, p2), rng: rng),
            ScheduleChromosome.makeChild(genes: child2Genes, parents: (p2, p1), rng: rng)
        )
    }

    // MARK: - Helper

    private static func makeGene(from base: ScheduleGene, withTimeOf donor: ScheduleGene) -> ScheduleGene {
        // Inherit the donor's full placement (startTime + slotIndex)
        // so strategy-level crossover flows through the same slot-
        // decoder invariant the inline loops above already honour.
        base.withPlacement(from: donor)
    }
}
