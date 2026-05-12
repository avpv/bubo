import Foundation

// MARK: - Diffusion Schedule Refinement (Wave 5 / item 20)
//
// Denoising diffusion of schedule start-times as a post-GA polish
// pass. Given a near-optimal chromosome, perturb each gene's start-
// time with Gaussian noise at increasing magnitude, then iteratively
// denoise back toward a *different* optimum via a score-function
// estimate: the local gradient of fitness w.r.t. each gene's offset.
//
// Why not just do gradient descent? Two reasons:
//   1. The fitness landscape is piecewise-constant in integer
//      minutes (objectives re-score in buckets). Direct gradient
//      descent would stall. Adding noise (diffusion forward) lifts
//      us off the plateau; denoising (backward) walks downhill.
//   2. Diffusion produces *distributional* variation — the polished
//      chromosome is a sample from a neighbourhood of good solutions,
//      not the closest deterministic optimum. Combined with MAP-
//      Elites this adds diversity to the archive for free.
//
// The score function is estimated by a simple central-difference on
// the evaluator: for each gene, compute fitness at ±ε offsets and
// use the difference as a gradient proxy. Cheap — O(N · 2) evals
// per denoising step. Not exact, but sufficient for a polish pass.

public struct DiffusionRefinementResult: Sendable {

    public init(
        refined: ScheduleChromosome,
        improvedVsInput: Bool,
        stepsRun: Int,
        evaluationsPerformed: Int
    ) {
        self.refined = refined
        self.improvedVsInput = improvedVsInput
        self.stepsRun = stepsRun
        self.evaluationsPerformed = evaluationsPerformed
    }

    public let refined: ScheduleChromosome
    public let improvedVsInput: Bool
    public let stepsRun: Int
    public let evaluationsPerformed: Int
}

public enum DiffusionRefinement {
    public struct Configuration: Sendable {

        public init(
            stepCount: Int,
            initialSigmaMinutes: Double,
            gradientEpsilonMinutes: Double,
            maxStepSizeMinutes: Double
        ) {
            self.stepCount = stepCount
            self.initialSigmaMinutes = initialSigmaMinutes
            self.gradientEpsilonMinutes = gradientEpsilonMinutes
            self.maxStepSizeMinutes = maxStepSizeMinutes
        }

        /// Number of diffusion steps to run. Higher = better
        /// smoothing, linearly more cost.
        public let stepCount: Int
        /// Initial noise scale (minutes). Halves each step (cosine
        /// schedule would be smoother but linear is fine at this
        /// depth).
        public let initialSigmaMinutes: Double
        /// Step size (minutes) used for the finite-difference
        /// gradient estimate.
        public let gradientEpsilonMinutes: Double
        /// Maximum move per gene per step (minutes). Clipping keeps
        /// the refinement bounded around the input chromosome.
        public let maxStepSizeMinutes: Double

        public static let `default` = Configuration(
            stepCount: 6,
            initialSigmaMinutes: 20,
            gradientEpsilonMinutes: 5,
            maxStepSizeMinutes: 15
        )

        public static let gentle = Configuration(
            stepCount: 3,
            initialSigmaMinutes: 10,
            gradientEpsilonMinutes: 3,
            maxStepSizeMinutes: 7
        )
    }

    /// Run denoising diffusion starting from `input`. Returns the
    /// best chromosome seen during the walk — never worse than the
    /// input, because we keep a best-so-far register.
    public static func refine(
        input: ScheduleChromosome,
        context: OptimizerContext,
        evaluate: (inout ScheduleChromosome) -> Void,
        config: Configuration = .default
    ) -> DiffusionRefinementResult {
        var current = input
        // Ensure evaluation.
        current.needsEvaluation = true
        evaluate(&current)
        var bestSeen = current
        var evalCount = 1
        let rng = context.rng
        let cal = context.calendar
        let slotRegistry = context.ensureSlotRegistry()

        for step in 0..<config.stepCount {
            let sigma = config.initialSigmaMinutes * pow(0.5, Double(step))

            // Forward: perturb each gene.
            var perturbed = current
            for i in perturbed.genes.indices {
                let noise = rng.gaussian(mean: 0, stdDev: sigma) * 60 // seconds
                let newStart = perturbed.genes[i].startTime.addingTimeInterval(noise)
                perturbed.genes[i] = perturbed.genes[i].withSlot(nearest: newStart, registry: slotRegistry)
            }
            perturbed.needsEvaluation = true
            clipToHorizon(&perturbed, context: context, cal: cal)
            perturbed.repair(context: context)
            evaluate(&perturbed)
            evalCount += 1

            // Backward: finite-difference gradient per gene.
            var denoised = perturbed
            let eps = config.gradientEpsilonMinutes * 60
            for i in denoised.genes.indices {
                var plus = denoised
                let plusDate = plus.genes[i].startTime.addingTimeInterval(eps)
                plus.genes[i] = plus.genes[i].withSlot(nearest: plusDate, registry: slotRegistry)
                plus.needsEvaluation = true
                evaluate(&plus)
                evalCount += 1

                var minus = denoised
                let minusDate = minus.genes[i].startTime.addingTimeInterval(-eps)
                minus.genes[i] = minus.genes[i].withSlot(nearest: minusDate, registry: slotRegistry)
                minus.needsEvaluation = true
                evaluate(&minus)
                evalCount += 1

                let grad = (plus.rawFitness - minus.rawFitness) / (2 * eps)
                // Update direction: move gene startTime to *increase*
                // fitness → positive grad means plus was better →
                // push in +ε direction. Clipped by maxStepSizeMinutes.
                let rawStep = grad * 60 * 10 // scale gradient (seconds/minute)
                let clampedStep = max(
                    -config.maxStepSizeMinutes * 60,
                    min(config.maxStepSizeMinutes * 60, rawStep)
                )
                let nextStart = denoised.genes[i].startTime.addingTimeInterval(clampedStep)
                denoised.genes[i] = denoised.genes[i].withSlot(nearest: nextStart, registry: slotRegistry)
            }
            denoised.needsEvaluation = true
            clipToHorizon(&denoised, context: context, cal: cal)
            denoised.repair(context: context)
            evaluate(&denoised)
            evalCount += 1

            if denoised.rawFitness > bestSeen.rawFitness {
                bestSeen = denoised
            }
            current = denoised
        }
        return DiffusionRefinementResult(
            refined: bestSeen,
            improvedVsInput: bestSeen.rawFitness > input.rawFitness,
            stepsRun: config.stepCount,
            evaluationsPerformed: evalCount
        )
    }

    // MARK: - Clipping

    private static func clipToHorizon(
        _ chromosome: inout ScheduleChromosome,
        context: OptimizerContext,
        cal: Calendar
    ) {
        let start = context.planningHorizon.start
        let end = context.planningHorizon.end
        let slotRegistry = context.ensureSlotRegistry()
        for i in chromosome.genes.indices {
            let gene = chromosome.genes[i]
            if gene.startTime < start {
                chromosome.genes[i] = gene.withSlot(nearest: start, registry: slotRegistry)
            } else if gene.endTime > end {
                let adjustedStart = end.addingTimeInterval(-gene.duration)
                chromosome.genes[i] = gene.withSlot(nearest: max(start, adjustedStart), registry: slotRegistry)
            }
        }
    }
}
