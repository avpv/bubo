import Foundation

// MARK: - Crossover Strategy

enum CrossoverStrategy: Sendable {
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

    /// Differential evolution recombination on the time-offset dimension:
    ///     child.startTime = p1.startTime + F · (p2.startTime − p1.startTime)
    /// where F is a scaling factor ∈ (0, 1]. Unlike categorical crossover
    /// strategies, DE exploits the fact that "10am ±15min" is a continuous
    /// neighbourhood — the child's time is a genuine interpolation between
    /// parents rather than a pick-one-or-the-other swap. Each gene's
    /// interpolation is sampled independently with probability CR
    /// (crossover rate), otherwise the child keeps parent 1's slot. F and
    /// CR ship with literature-standard defaults (F=0.5, CR=0.9) so the
    /// call site stays ergonomic; override for more exploration.
    case differentialEvolution(F: Double, CR: Double)
}

// MARK: - Crossover

/// Crossover operators for schedule chromosomes.
enum Crossover {

    /// Perform crossover on two parents using the given strategy.
    static func perform(
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
        case .differentialEvolution(let F, let CR):
            return differentialEvolutionCrossover(parent1, parent2, F: F, CR: CR, context: context)
        }
    }

    // MARK: - Differential Evolution Crossover

    /// DE/rand/1-style arithmetic recombination on the time dimension. For
    /// each positionally-aligned gene pair we sample a decision r ∈ [0, 1]:
    ///
    ///   r < CR →  child1.startTime = p1.startTime + F · (p2 − p1)
    ///             child2.startTime = p2.startTime − F · (p2 − p1)
    ///   r ≥ CR →  children keep their primary parent's slot
    ///
    /// The resulting time is then clamped to working hours and the floor
    /// (earliest-start / horizon bounds), so infeasible extrapolations are
    /// snapped to the nearest legal position. Compared with positional
    /// swaps, DE lets the GA refine minute-level offsets without spending
    /// an entire `mutate()` call — especially useful late in evolution
    /// when the population has locked onto a structural layout and only
    /// the exact minute is still under search.
    ///
    /// Locked genes are returned verbatim; `withStartTime` on a locked
    /// gene already no-ops, but explicit handling here keeps the code
    /// path obvious for future readers.
    private static func differentialEvolutionCrossover(
        _ p1: ScheduleChromosome,
        _ p2: ScheduleChromosome,
        F: Double,
        CR: Double,
        context: OptimizerContext
    ) -> (ScheduleChromosome, ScheduleChromosome) {
        guard p1.genes.count == p2.genes.count, !p1.genes.isEmpty else {
            return (p1, p2)
        }
        let rng = context.rng
        let cal = context.calendar
        let horizonStart = context.planningHorizon.start
        let clampedF = min(1.0, max(0.05, F))
        let clampedCR = min(1.0, max(0.0, CR))

        var child1Genes = p1.genes
        var child2Genes = p2.genes

        for i in p1.genes.indices {
            guard p1.genes[i].eventId == p2.genes[i].eventId else { continue }
            if p1.genes[i].isLocked || p2.genes[i].isLocked { continue }
            guard rng.double(in: 0.0...1.0) < clampedCR else { continue }

            let t1 = p1.genes[i].startTime.timeIntervalSinceReferenceDate
            let t2 = p2.genes[i].startTime.timeIntervalSinceReferenceDate
            let delta = t2 - t1

            // Symmetric pair: one child interpolates toward p2, the other
            // extrapolates away. DE's hallmark — forwards *and* backwards
            // step so the offspring cover both sides of the parent line.
            let blended1 = Date(timeIntervalSinceReferenceDate: t1 + clampedF * delta)
            let blended2 = Date(timeIntervalSinceReferenceDate: t2 - clampedF * delta)

            // Floor per event so dependencies/earliestStart aren't violated
            // by the arithmetic. Subsequent repair() finalises feasibility.
            let event = context.movableEvents.first { $0.id == p1.genes[i].eventId }
            let earliest = event?.earliestStart
            let floor = [horizonStart, earliest].compactMap { $0 }.max() ?? horizonStart

            let c1Start = clampToWorkingHours(
                max(blended1, floor),
                duration: p1.genes[i].duration,
                workingHours: context.workingHours,
                calendar: cal,
                floor: floor
            )
            let c2Start = clampToWorkingHours(
                max(blended2, floor),
                duration: p2.genes[i].duration,
                workingHours: context.workingHours,
                calendar: cal,
                floor: floor
            )

            child1Genes[i] = p1.genes[i].withStartTime(c1Start)
            child2Genes[i] = p2.genes[i].withStartTime(c2Start)
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
                child1Genes[i] = p1.genes[i].withStartTime(p2.genes[i].startTime)
            }

            // Mirror for child2 using its own parent's grouping. Reading the
            // same day map — decision flipped — keeps the pair Pareto-paired
            // (nothing is discarded on both children simultaneously).
            let p2Day = cal.startOfDay(for: p2.genes[i].startTime)
            if takeFromP2[p2Day] == false {
                child2Genes[i] = p2.genes[i].withStartTime(p1.genes[i].startTime)
            }
        }

        return (
            ScheduleChromosome.makeChild(genes: child1Genes, parents: (p1, p2), rng: rng),
            ScheduleChromosome.makeChild(genes: child2Genes, parents: (p2, p1), rng: rng)
        )
    }

    // MARK: - Helper

    private static func makeGene(from base: ScheduleGene, withTimeOf donor: ScheduleGene) -> ScheduleGene {
        base.withStartTime(donor.startTime)
    }
}
