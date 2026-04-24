import Foundation
import os

private let logger = Logger(subsystem: "com.avpv.Bubo", category: "Optimizer/Reoptimizer")

// MARK: - #26 Incremental Re-optimizer

/// Handles mid-day schedule changes without full re-optimization.
/// Seeds the GA with the current schedule and freezes events that already happened.
/// Thread safety: a fresh instance is created per reoptimize() call in BuboOptimizer.
final class IncrementalReoptimizer: @unchecked Sendable {

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
        let startedAt = Date()
        let now = startedAt
        logger.info("reoptimize_triggered trigger=\(trigger.logName, privacy: .public) stability_weight=\(self.stabilityWeight) schedule_size=\(currentSchedule.count)")

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

        // Forward bandit/head from the caller's context so the
        // reoptimizer doesn't fork a parallel learner state. When the
        // caller is `BuboOptimizer.optimize`, this means the
        // incremental reoptimizer shares the same per-workload bundle
        // and learning carries through. When called directly with a
        // raw context, the default-initialized learners on `context`
        // are forwarded as-is.
        //
        // `cpSATRepairer` and `cpSATWindowThreshold` are carried
        // forward too so the `AnchorSeeder` below can attempt a
        // warm-started CP-SAT seed for the reduced (future-movable)
        // sub-problem. When the caller omits a repairer the seeder
        // reports `.greedy(.disabled)` and the path behaves exactly
        // as before.
        let adjustedContext = OptimizerContext(
            fixedEvents: context.fixedEvents + frozenGenesToEvents(frozenGenes),
            movableEvents: futureMovable,
            workingHours: context.workingHours,
            planningHorizon: DateInterval(start: now, end: context.planningHorizon.end),
            preferences: context.preferences,
            participantAvailability: context.participantAvailability,
            calendar: context.calendar,
            mutationBandit: context.mutationBandit,
            lnsStrategyBandit: context.lnsStrategyBandit,
            contextualCrossoverHead: context.contextualCrossoverHead,
            cpSATRepairer: context.cpSATRepairer,
            cpSATWindowThreshold: context.cpSATWindowThreshold
        )

        guard !futureMovable.isEmpty else {
            logger.info("reoptimize_result outcome=skipped reason=no_future_movable frozen=\(frozenGenes.count)")
            return nil
        }

        // 3. Evaluate current schedule fitness for comparison
        var currentChromosome = ScheduleChromosome(genes: movableGenes)
        evaluator.evaluateAndAssign(&currentChromosome, context: adjustedContext)
        let currentFitness = currentChromosome.fitness

        // 4. Produce the seed population.
        //    The warm-started CP-SAT anchor comes first so it's
        //    always in the initial set — when the current schedule
        //    is still feasible under the new context it feeds the
        //    solver a tight starting incumbent; when it isn't, the
        //    lex hierarchy fixes it before GA polish. Greedy
        //    variants of `movableGenes` fill the rest of the seed
        //    population for local exploration around the current
        //    state.
        // Gates default to `cpsatEnabled: true`; the seeder itself
        // resolves `context.cpSATRepairer == nil` to
        // `.greedy(.disabled)`. This keeps the feature-flag decision
        // in `BuboOptimizer.makeReoptContext(from:)` — the reopt
        // path only has to forward the context it was given.
        let seeder = AnchorSeeder(gates: AnchorSeeder.Gates(
            cpsatEnabled: true,
            windowThreshold: context.cpSATWindowThreshold
        ))
        let (anchorSeed, anchorProvenance) = seeder.makeAnchor(
            context: adjustedContext,
            mode: .reopt(currentSchedule: movableGenes)
        )
        logger.info("reoptimize_anchor source=\(anchorProvenance.logLabel, privacy: .public) cpsat_ms=\(anchorProvenance.cpsatDurationMs)")

        var seeds = createSeeds(
            from: movableGenes,
            count: max(1, config.populationSize / 3),
            context: adjustedContext
        )
        seeds.insert(anchorSeed, at: 0)

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
                let score = stabilityEvaluator.evaluate(
                    chromosome: chromosome,
                    context: adjustedContext
                )
                chromosome.fitness = score
                chromosome.rawFitness = score
                // StabilityEvaluator is a ground-truth evaluator
                // (wraps the real FitnessEvaluator + a penalty term);
                // the resulting score is not a surrogate prediction.
                chromosome.isFitnessReal = true
            }
        )

        // `runSeeded` is `throws` for cooperative cancellation; the
        // incremental reoptimizer is synchronous and tolerates no
        // cancellation, so we swallow any error and fall back to
        // "no improvement found" semantics.
        let results: [ScheduleChromosome]
        do {
            results = try ga.runSeeded(with: seeds)
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            logger.warning("reoptimize_result outcome=failed reason=ga_error error=\(error.localizedDescription, privacy: .public) duration_ms=\(durationMs)")
            return nil
        }

        // 6. Check if the new schedule is significantly better
        guard let best = results.first else {
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            logger.info("reoptimize_result outcome=rejected reason=no_results duration_ms=\(durationMs)")
            return nil
        }

        let improvement = best.fitness - currentFitness
        guard improvement > minimumImprovement else {
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            logger.info("reoptimize_result outcome=rejected reason=below_threshold improvement=\(improvement) threshold=\(self.minimumImprovement) duration_ms=\(durationMs)")
            return nil
        }

        // 7. Merge frozen + new movable genes
        let finalGenes = frozenGenes + best.genes

        let scenario = ScheduleScenario(
            genes: finalGenes,
            fitness: best.fitness,
            objectiveBreakdown: evaluator.objectiveBreakdown(for: best, context: adjustedContext),
            constraintViolations: evaluator.constraintEngine.violations(for: best, context: adjustedContext)
        )

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        logger.info("reoptimize_result outcome=accepted improvement=\(improvement) fitness=\(best.fitness) frozen=\(frozenGenes.count) movable=\(best.genes.count) generations=\(ga.convergenceGeneration) duration_ms=\(durationMs)")

        return OptimizerResult(
            scenarios: [scenario],
            metadata: OptimizationMetadata(
                generations: ga.convergenceGeneration,
                totalDuration: 0,
                bestFitness: best.fitness,
                averageFitness: results.isEmpty ? 0 : results.prefix(10).reduce(0) { $0 + $1.fitness } / Double(min(10, results.count)),
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
            if gene.startTime < freezeBefore {
                // Freeze events that have already started (in-progress or completed)
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
                title: gene.title,
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

    /// Create seed chromosomes from graduated perturbations of the current schedule.
    /// Seeds range from near-copies (small tweaks) to more exploratory variants,
    /// giving the GA both exploitation and exploration starting points.
    private func createSeeds(
        from current: [ScheduleGene],
        count: Int,
        context: OptimizerContext
    ) -> [ScheduleChromosome] {
        var seeds: [ScheduleChromosome] = []

        // The current schedule is always a seed (exact copy)
        seeds.append(ScheduleChromosome(genes: current))

        // Create graduated variants: low mutation → high mutation
        for i in 1..<count {
            var variant = ScheduleChromosome(genes: current)
            // Graduated rate: early seeds are conservative (0.1), later ones are exploratory (0.6)
            let progress = Double(i) / Double(max(1, count - 1))
            let rate = 0.1 + progress * 0.5
            variant.mutate(rate: rate, context: context)
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

enum ReoptimizationTrigger: Sendable {
    case newEvent(OptimizableEvent)
    case cancelledEvent(eventId: String)
    case movedEvent(eventId: String, newStart: Date)
    case preferencesChanged
    case periodicRefresh

    /// Stable snake_case label for structured logs. Associated values
    /// are deliberately dropped — the event IDs and dates inside them
    /// would make aggregation (e.g. counting triggers by kind) useless.
    var logName: String {
        switch self {
        case .newEvent: return "new_event"
        case .cancelledEvent: return "cancelled_event"
        case .movedEvent: return "moved_event"
        case .preferencesChanged: return "preferences_changed"
        case .periodicRefresh: return "periodic_refresh"
        }
    }
}

// MARK: - Stability-Aware Fitness Evaluator

/// Adds a stability penalty to the base fitness, discouraging unnecessary changes.
struct StabilityAwareFitnessEvaluator: Sendable {
    let base: FitnessEvaluator
    let referenceGenes: [ScheduleGene]
    let stabilityWeight: Double

    func evaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        let baseFitness = base.evaluate(chromosome: chromosome, context: context)

        // Calculate deviation from reference schedule
        var totalDeviation = 0.0
        for gene in chromosome.genes where gene.isIncluded {
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
