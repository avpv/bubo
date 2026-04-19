import Foundation

// MARK: - Diffusion Schedule Refinement (Wave 5 / п.20)
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

struct DiffusionRefinementResult: Sendable {
    let refined: ScheduleChromosome
    let improvedVsInput: Bool
    let stepsRun: Int
    let evaluationsPerformed: Int
}

enum DiffusionRefinement {
    struct Configuration: Sendable {
        /// Number of diffusion steps to run. Higher = better
        /// smoothing, linearly more cost.
        let stepCount: Int
        /// Initial noise scale (minutes). Halves each step (cosine
        /// schedule would be smoother but linear is fine at this
        /// depth).
        let initialSigmaMinutes: Double
        /// Step size (minutes) used for the finite-difference
        /// gradient estimate.
        let gradientEpsilonMinutes: Double
        /// Maximum move per gene per step (minutes). Clipping keeps
        /// the refinement bounded around the input chromosome.
        let maxStepSizeMinutes: Double

        static let `default` = Configuration(
            stepCount: 6,
            initialSigmaMinutes: 20,
            gradientEpsilonMinutes: 5,
            maxStepSizeMinutes: 15
        )

        static let gentle = Configuration(
            stepCount: 3,
            initialSigmaMinutes: 10,
            gradientEpsilonMinutes: 3,
            maxStepSizeMinutes: 7
        )
    }

    /// Run denoising diffusion starting from `input`. Returns the
    /// best chromosome seen during the walk — never worse than the
    /// input, because we keep a best-so-far register.
    static func refine(
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

        for step in 0..<config.stepCount {
            let sigma = config.initialSigmaMinutes * pow(0.5, Double(step))

            // Forward: perturb each gene.
            var perturbed = current
            for i in perturbed.genes.indices {
                let noise = rng.gaussian(mean: 0, stdDev: sigma) * 60 // seconds
                perturbed.genes[i] = perturbed.genes[i].withStartTime(
                    perturbed.genes[i].startTime.addingTimeInterval(noise)
                )
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
                plus.genes[i] = plus.genes[i].withStartTime(
                    plus.genes[i].startTime.addingTimeInterval(eps)
                )
                plus.needsEvaluation = true
                evaluate(&plus)
                evalCount += 1

                var minus = denoised
                minus.genes[i] = minus.genes[i].withStartTime(
                    minus.genes[i].startTime.addingTimeInterval(-eps)
                )
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
                denoised.genes[i] = denoised.genes[i].withStartTime(
                    denoised.genes[i].startTime.addingTimeInterval(clampedStep)
                )
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
        for i in chromosome.genes.indices {
            let gene = chromosome.genes[i]
            if gene.startTime < start {
                chromosome.genes[i] = gene.withStartTime(start)
            } else if gene.endTime > end {
                let adjustedStart = end.addingTimeInterval(-gene.duration)
                chromosome.genes[i] = gene.withStartTime(max(start, adjustedStart))
            }
        }
    }
}
