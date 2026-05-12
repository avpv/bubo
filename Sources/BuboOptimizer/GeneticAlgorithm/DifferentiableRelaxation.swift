import Foundation

// MARK: - Finite-Difference Schedule Refiner
//
// Calendar scheduling is discrete (slot choice + inclusion flag), but
// many of its objectives are locally smooth in a continuous
// relaxation of slot start time. If we treat each gene's start as a
// real-valued offset, estimate `∂fitness/∂t` by finite difference,
// and step in the gradient direction, we can refine an already-good
// chromosome toward a local optimum that pure stochastic mutation
// would take dozens of generations to reach.
//
// This is **not** DARTS-style autograd-on-soft-assignment. The fitness
// evaluator has no autograd surface. We do honest finite differences:
// 2 fitness evaluations per gene per pass to estimate the gradient,
// then a clamped step. Cost is `2·passes·sampleFraction·N` extra
// evaluations per refined chromosome — call it on top elites only,
// every Nth generation.
//
// Why "clamped step with sign×min(|grad|, 1)" instead of raw Euler:
//   • Pure gradient descent on a discretized objective oscillates
//     because each evaluation includes a repair pass that re-snaps to
//     valid slots. Sign + clamped magnitude treats the gradient as a
//     direction with confidence-weighted step size, which is stable
//     under repair noise without needing a trust-region wrapper.
//   • Momentum smooths consistent gradient signals across passes
//     while damping noisy cancellations.

/// Finite-difference gradient refiner for `ScheduleChromosome`.
public struct ScheduleGradientRefiner: Sendable {
    public struct Configuration: Sendable {

        public init(
            stepSeconds: TimeInterval,
            learningRate: TimeInterval,
            maxStepSeconds: TimeInterval,
            passes: Int,
            momentum: Double,
            sampleFraction: Double
        ) {
            self.stepSeconds = stepSeconds
            self.learningRate = learningRate
            self.maxStepSeconds = maxStepSeconds
            self.passes = passes
            self.momentum = momentum
            self.sampleFraction = sampleFraction
        }

        /// Finite-difference step in seconds. 300s = 5 min, the
        /// smallest resolution the calendar engine cares about.
        let stepSeconds: TimeInterval
        /// Learning rate in seconds per unit gradient. Translates the
        /// dimensionless gradient into a wall-clock time shift.
        let learningRate: TimeInterval
        /// Maximum per-step shift in seconds. Keeps the gene in the
        /// neighbourhood of its current slot — refinement is a
        /// fine-tuner, not a teleporter.
        let maxStepSeconds: TimeInterval
        /// Number of gradient passes.
        let passes: Int
        /// Momentum on the per-gene gradient estimate. Smooths noise
        /// from the repair operator nudging overlaps between steps.
        let momentum: Double
        /// Fraction of included genes updated per pass. Sampling a
        /// subset bounds cost on large schedules.
        let sampleFraction: Double

        static let `default` = Configuration(
            stepSeconds: 300,
            learningRate: 600,
            maxStepSeconds: 1800,
            passes: 4,
            momentum: 0.4,
            sampleFraction: 1.0
        )

        static let aggressive = Configuration(
            stepSeconds: 600,
            learningRate: 1200,
            maxStepSeconds: 3600,
            passes: 6,
            momentum: 0.6,
            sampleFraction: 1.0
        )
    }

    public let config: Configuration

    public init(config: Configuration = .default) {
        self.config = config
    }

    /// Refine `chromosome` in-place. `evaluate` must populate both
    /// `fitness` and `rawFitness`. The caller is responsible for
    /// ensuring `chromosome.rawFitness` is fresh on entry — this
    /// method does *not* re-evaluate the input.
    ///
    /// Returns the fitness improvement over the input
    /// (non-negative — the refiner returns the better of input and
    /// refined state).
    @discardableResult
    public func refine(
        _ chromosome: inout ScheduleChromosome,
        context: OptimizerContext,
        evaluate: (inout ScheduleChromosome) -> Void
    ) -> Double {
        let initialFitness = chromosome.rawFitness
        let horizonStart = context.planningHorizon.start
        let horizonEnd = context.planningHorizon.end
        let cal = context.calendar
        let slotRegistry = context.ensureSlotRegistry()

        var velocity = [TimeInterval](repeating: 0, count: chromosome.genes.count)

        var best = chromosome
        var bestFitness = initialFitness

        for _ in 0..<config.passes {
            let includedIndices = chromosome.genes.indices.filter { chromosome.genes[$0].isIncluded }
            let sampleCount = max(1, Int(Double(includedIndices.count) * max(0, min(1, config.sampleFraction))))
            let sampled: [Int]
            if sampleCount >= includedIndices.count {
                sampled = includedIndices
            } else {
                sampled = Array(context.rng.shuffled(includedIndices).prefix(sampleCount))
            }

            for geneIdx in sampled {
                let originalStart = chromosome.genes[geneIdx].startTime
                let h = config.stepSeconds

                // Build the + and − probe chromosomes for finite
                // difference. We deliberately skip `repair()` on the
                // probes and instead mark `mutatedGeneIndices` so the
                // evaluator's delta path re-scores only the affected
                // day(s) via `DayPartitionedObjective.evaluateOneDay`.
                // Any new overlap introduced by the step is scored
                // via the ConstraintEngine penalty — the gradient
                // direction will naturally reject it, which is the
                // correct outcome (we don't want to push into
                // infeasibility).
                var plus = chromosome
                let plusDate = clampToWorkingHours(
                    originalStart.addingTimeInterval(h),
                    duration: plus.genes[geneIdx].duration,
                    workingHours: context.workingHours,
                    calendar: cal,
                    floor: horizonStart
                )
                plus.genes[geneIdx] = plus.genes[geneIdx].withSlot(nearest: plusDate, registry: slotRegistry)
                plus.mutatedGeneIndices = IndexSet(integer: geneIdx)
                plus.needsEvaluation = true
                evaluate(&plus)
                let fPlus = plus.rawFitness

                var minus = chromosome
                let minusDate = clampToWorkingHours(
                    originalStart.addingTimeInterval(-h),
                    duration: minus.genes[geneIdx].duration,
                    workingHours: context.workingHours,
                    calendar: cal,
                    floor: horizonStart
                )
                minus.genes[geneIdx] = minus.genes[geneIdx].withSlot(nearest: minusDate, registry: slotRegistry)
                minus.mutatedGeneIndices = IndexSet(integer: geneIdx)
                minus.needsEvaluation = true
                evaluate(&minus)
                let fMinus = minus.rawFitness

                let grad = (fPlus - fMinus) / (2.0 * h)
                let clampedGrad = max(-1.0, min(1.0, grad))

                let rawStep = config.learningRate * clampedGrad
                velocity[geneIdx] = config.momentum * velocity[geneIdx] + (1.0 - config.momentum) * rawStep
                let step = max(-config.maxStepSeconds, min(config.maxStepSeconds, velocity[geneIdx]))

                var newStart = originalStart.addingTimeInterval(step)
                if newStart < horizonStart { newStart = horizonStart }
                if newStart.addingTimeInterval(chromosome.genes[geneIdx].duration) > horizonEnd {
                    newStart = horizonEnd.addingTimeInterval(-chromosome.genes[geneIdx].duration)
                }
                newStart = clampToWorkingHours(
                    newStart,
                    duration: chromosome.genes[geneIdx].duration,
                    workingHours: context.workingHours,
                    calendar: cal,
                    floor: horizonStart
                )
                chromosome.genes[geneIdx] = chromosome.genes[geneIdx].withSlot(nearest: newStart, registry: slotRegistry)
            }

            chromosome.repair(context: context)
            evaluate(&chromosome)

            if chromosome.rawFitness > bestFitness {
                best = chromosome
                bestFitness = chromosome.rawFitness
            }
        }

        // Always return the best state seen — gradient refinement is
        // not monotonic under repair noise, so we don't trust the
        // final pass.
        chromosome = best
        return max(0, bestFitness - initialFitness)
    }
}

// Backwards-name alias removed: `SoftSlotAssignment` was scaffolding
// for an autograd-backed extension that was never implemented. Until
// there's a real gradient backend wired (MLX/JAX) the type was dead
// code; a future implementer can introduce it then.
