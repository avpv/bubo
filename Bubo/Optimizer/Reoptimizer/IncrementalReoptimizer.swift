import Foundation

// MARK: - #26 Incremental Re-optimizer

/// Handles mid-day schedule changes without full re-optimization.
/// Seeds the GA with the current schedule and freezes events that already happened.
final class IncrementalReoptimizer {

    /// Stability penalty weight — how much we penalize deviation from current schedule.
    var stabilityWeight: Double = 2.0

    /// Minimum fitness improvement required to suggest a new schedule.
    var minimumImprovement: Double = 0.05

    // MARK: - Re-optimize

    /// Re-optimize the schedule after a change (new event, cancellation, etc.).
    /// - Parameters:
    ///   - currentSchedule: The current set of movable event placements.
    ///   - trigger: What caused the re-optimization.
    ///   - context: The optimizer context (may have changed since last optimization).
    ///   - evaluator: The fitness evaluator to use.
    ///   - config: GA configuration (uses .quick by default for responsiveness).
    /// - Returns: A new schedule if it's significantly better, nil otherwise.
    func reoptimize(
        currentSchedule: [ScheduleGene],
        trigger: ReoptimizationTrigger,
        context: OptimizerContext,
        evaluator: FitnessEvaluator,
        config: GAConfiguration = .quick
    ) -> OptimizerResult? {
        let now = Date()

        // 1. Separate frozen and movable genes
        let (frozenGenes, movableGenes) = partitionGenes(
            currentSchedule,
            freezeBefore: now,
            context: context
        )

        // 2. Create a modified context that only includes future movable events
        let futureMovable = context.movableEvents.filter { event in
            movableGenes.contains { $0.eventId == event.id }
        }

        let adjustedContext = OptimizerContext(
            fixedEvents: context.fixedEvents + frozenGenesToEvents(frozenGenes),
            movableEvents: futureMovable,
            workingHours: context.workingHours,
            planningHorizon: DateInterval(start: now, end: context.planningHorizon.end),
            preferences: context.preferences,
            participantAvailability: context.participantAvailability,
            calendar: context.calendar
        )

        guard !futureMovable.isEmpty else { return nil }

        // 3. Evaluate current schedule fitness for comparison
        var currentChromosome = ScheduleChromosome(genes: movableGenes)
        evaluator.evaluateAndAssign(&currentChromosome, context: adjustedContext)
        let currentFitness = currentChromosome.fitness

        // 4. Create seed population from variants of current schedule
        let seeds = createSeeds(
            from: movableGenes,
            count: config.populationSize / 3,
            context: adjustedContext
        )

        // 5. Run GA with stability-aware fitness
        let stabilityEvaluator = makeStabilityAwareEvaluator(
            base: evaluator,
            reference: movableGenes,
            stabilityWeight: stabilityWeight
        )

        let ga = GeneticAlgorithm<ScheduleChromosome>(
            config: config,
            context: adjustedContext,
            evaluate: { chromosome in
                chromosome.fitness = stabilityEvaluator.evaluate(
                    chromosome: chromosome,
                    context: adjustedContext
                )
            }
        )

        let results = ga.runSeeded(with: seeds)

        // 6. Check if the new schedule is significantly better
        guard let best = results.first else { return nil }

        let improvement = best.fitness - currentFitness
        guard improvement > minimumImprovement else { return nil }

        // 7. Merge frozen + new movable genes
        let finalGenes = frozenGenes + best.genes

        let scenario = ScheduleScenario(
            genes: finalGenes,
            fitness: best.fitness,
            objectiveBreakdown: evaluator.objectiveBreakdown(for: best, context: adjustedContext),
            constraintViolations: evaluator.constraintEngine.violations(for: best, context: adjustedContext)
        )

        return OptimizerResult(
            scenarios: [scenario],
            metadata: OptimizationMetadata(
                generations: ga.convergenceGeneration,
                totalDuration: 0,
                bestFitness: best.fitness,
                averageFitness: results.prefix(10).reduce(0) { $0 + $1.fitness } / Double(min(10, results.count)),
                convergenceGeneration: ga.convergenceGeneration
            )
        )
    }

    // MARK: - Partitioning

    /// Split genes into frozen (already happened or in progress) and movable (future).
    private func partitionGenes(
        _ genes: [ScheduleGene],
        freezeBefore: Date,
        context: OptimizerContext
    ) -> (frozen: [ScheduleGene], movable: [ScheduleGene]) {
        var frozen: [ScheduleGene] = []
        var movable: [ScheduleGene] = []

        for gene in genes {
            if gene.startTime < freezeBefore || gene.endTime < freezeBefore {
                frozen.append(gene)
            } else {
                movable.append(gene)
            }
        }
        return (frozen, movable)
    }

    /// Convert frozen genes to CalendarEvents (they become "fixed" for the re-optimization).
    private func frozenGenesToEvents(_ genes: [ScheduleGene]) -> [CalendarEvent] {
        genes.map { gene in
            CalendarEvent(
                id: gene.eventId,
                title: gene.eventId,
                startDate: gene.startTime,
                endDate: gene.endTime,
                location: nil,
                description: nil,
                calendarName: "Frozen",
                eventType: .standard
            )
        }
    }

    // MARK: - Seeding

    /// Create seed chromosomes from variants of the current schedule.
    private func createSeeds(
        from current: [ScheduleGene],
        count: Int,
        context: OptimizerContext
    ) -> [ScheduleChromosome] {
        var seeds: [ScheduleChromosome] = []

        // The current schedule is always a seed
        seeds.append(ScheduleChromosome(genes: current))

        // Create mutations of the current schedule
        for _ in 1..<count {
            var variant = ScheduleChromosome(genes: current)
            variant.mutate(rate: 0.3, context: context)
            seeds.append(variant)
        }

        return seeds
    }

    // MARK: - Stability-Aware Fitness

    /// Wraps the base evaluator to add a stability penalty for deviation from reference.
    private func makeStabilityAwareEvaluator(
        base: FitnessEvaluator,
        reference: [ScheduleGene],
        stabilityWeight: Double
    ) -> StabilityAwareFitnessEvaluator {
        StabilityAwareFitnessEvaluator(
            base: base,
            referenceGenes: reference,
            stabilityWeight: stabilityWeight
        )
    }
}

// MARK: - Reoptimization Trigger

enum ReoptimizationTrigger {
    case newEvent(OptimizableEvent)
    case cancelledEvent(eventId: String)
    case movedEvent(eventId: String, newStart: Date)
    case preferencesChanged
    case periodicRefresh
}

// MARK: - Stability-Aware Fitness Evaluator

/// Adds a stability penalty to the base fitness, discouraging unnecessary changes.
struct StabilityAwareFitnessEvaluator {
    let base: FitnessEvaluator
    let referenceGenes: [ScheduleGene]
    let stabilityWeight: Double

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let baseFitness = base.evaluate(chromosome: chromosome, context: context)

        // Calculate deviation from reference schedule
        var totalDeviation = 0.0
        for gene in chromosome.genes {
            if let ref = referenceGenes.first(where: { $0.eventId == gene.eventId }) {
                let timeDiff = abs(gene.startTime.timeIntervalSince(ref.startTime))
                totalDeviation += timeDiff / 3600  // in hours
            } else {
                totalDeviation += 2.0  // penalty for new/moved events
            }
        }

        // Apply stability as multiplicative factor to keep fitness positive
        let stabilityFactor = 1.0 / (1.0 + totalDeviation * stabilityWeight * 0.01)
        return baseFitness * stabilityFactor
    }
}
