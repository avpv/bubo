import Foundation

// MARK: - Differentiable Relaxation (GA + Gradient Hybrid)
//
// Calendar scheduling is discrete (slot choice + inclusion flag), but many
// of its objectives are locally smooth in a *continuous* relaxation of
// slot assignment. If we treat each gene's start time as a real-valued
// offset and step it along the gradient of the weighted fitness, we can
// refine already-good chromosomes toward local optima that discrete
// mutations would take dozens of generations to reach.
//
// This is deliberately *not* full DARTS — we don't run a parameterized
// slot-assignment softmax through the fitness function; instead we use
// finite-difference gradients in wall-clock seconds around each gene's
// current start, take small steps, and re-repair after each step. This
// avoids re-architecting the fitness evaluator while still capturing the
// "slide toward a better slot" signal that pure mutation can only
// approximate stochastically.
//
// Expected use: invoke on top-K elites every Nth generation alongside the
// existing memetic hill-climb. Hill climb explores neighbourhoods;
// gradient refine exploits smoothness — they're complementary.

/// Finite-difference gradient refinement for `ScheduleChromosome`.
///
/// Algorithm:
///   1. For each included gene, evaluate fitness at `t`, `t + h`, `t - h`.
///   2. Estimate `∂f/∂t_i ≈ (f(t_i + h) - f(t_i - h)) / (2h)`.
///   3. Apply a bounded step `t_i += lr · sign(∂f/∂t_i) · min(|∂f/∂t_i|, 1)`,
///      clamped to working hours and to the horizon.
///   4. Repair after each pass, then re-evaluate.
///
/// Bounded step with sign uses magnitude as a confidence signal, not a
/// raw Euler update. Pure gradient descent on a discretized objective
/// can easily oscillate; a clamped step behaves well under noise from
/// subsequent repair passes and keeps the refiner stable without needing
/// a trust region.
///
/// Thread safety: construct one per call site; no shared state.
struct DifferentiableRefiner: Sendable {
    struct Configuration: Sendable {
        /// Finite-difference step in seconds. 300s = 5 minutes — the
        /// smallest resolution the calendar engine cares about.
        let stepSeconds: TimeInterval
        /// Learning rate in seconds per unit gradient. Translates the
        /// dimensionless gradient into a wall-clock time shift.
        let learningRate: TimeInterval
        /// Maximum per-step shift (absolute value) in seconds. Keeps the
        /// gene in the neighbourhood of its current slot — gradient
        /// refinement is a fine-tuner, not a teleporter.
        let maxStepSeconds: TimeInterval
        /// Number of gradient passes.
        let passes: Int
        /// Momentum on the per-gene gradient estimate. Smooths out
        /// noise from the repair operator nudging overlaps between steps.
        let momentum: Double
        /// Fraction of included genes updated per pass. Sampling a subset
        /// keeps the refinement cost bounded on large schedules; 1.0
        /// updates every gene every pass.
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

    let config: Configuration

    init(config: Configuration = .default) {
        self.config = config
    }

    // MARK: - Entry point

    /// Refine `chromosome` in-place using finite-difference gradients.
    /// `evaluate` must populate both `fitness` and `rawFitness`. The
    /// caller is responsible for ensuring `chromosome.rawFitness` is
    /// fresh on entry (this method does *not* re-evaluate the input).
    ///
    /// Returns the fitness improvement over the input (non-negative; the
    /// refiner always returns the better of input and refined state).
    @discardableResult
    func refine(
        _ chromosome: inout ScheduleChromosome,
        context: OptimizerContext,
        evaluate: (inout ScheduleChromosome) -> Void
    ) -> Double {
        let initialFitness = chromosome.rawFitness
        let horizonStart = context.planningHorizon.start
        let horizonEnd = context.planningHorizon.end
        let cal = context.calendar

        // Per-gene momentum buffers indexed by gene position.
        var velocity = [TimeInterval](repeating: 0, count: chromosome.genes.count)

        var best = chromosome
        var bestFitness = initialFitness

        for _ in 0..<config.passes {
            // Collect indices of included genes; sample a random subset when
            // `sampleFraction < 1`.
            let includedIndices = chromosome.genes.indices.filter { chromosome.genes[$0].isIncluded }
            let sampleCount = max(1, Int(Double(includedIndices.count) * max(0, min(1, config.sampleFraction))))
            let sampled: [Int]
            if sampleCount >= includedIndices.count {
                sampled = includedIndices
            } else {
                sampled = Array(context.rng.shuffled(includedIndices).prefix(sampleCount))
            }

            // Compute gradients for sampled genes around their current time.
            // Each gradient is one + pass and one - pass perturbation and
            // evaluation. That's expensive (2 evals per gene per pass) —
            // caller controls cost via `passes` and `sampleFraction`.
            for geneIdx in sampled {
                let originalStart = chromosome.genes[geneIdx].startTime
                let h = config.stepSeconds

                // f(t + h)
                var plus = chromosome
                plus.genes[geneIdx] = plus.genes[geneIdx].withStartTime(
                    clampToWorkingHours(
                        originalStart.addingTimeInterval(h),
                        duration: plus.genes[geneIdx].duration,
                        workingHours: context.workingHours,
                        calendar: cal,
                        floor: horizonStart
                    )
                )
                plus.repair(context: context)
                evaluate(&plus)
                let fPlus = plus.rawFitness

                // f(t - h)
                var minus = chromosome
                minus.genes[geneIdx] = minus.genes[geneIdx].withStartTime(
                    clampToWorkingHours(
                        originalStart.addingTimeInterval(-h),
                        duration: minus.genes[geneIdx].duration,
                        workingHours: context.workingHours,
                        calendar: cal,
                        floor: horizonStart
                    )
                )
                minus.repair(context: context)
                evaluate(&minus)
                let fMinus = minus.rawFitness

                // Symmetric finite-difference gradient. Divide by 2h so the
                // magnitude is dimensionless (Δfitness per second).
                let grad = (fPlus - fMinus) / (2.0 * h)

                // Clamp gradient magnitude to 1.0 — any larger and we treat
                // it as "definitely go this way" without letting a large
                // raw value produce a runaway step. Preserves sign.
                let clampedGrad = max(-1.0, min(1.0, grad))

                // Momentum-smoothed step. `velocity` accumulates across
                // passes so a gene getting a consistent gradient signal
                // keeps shifting; noisy cancellations dampen quickly.
                let rawStep = config.learningRate * clampedGrad
                velocity[geneIdx] = config.momentum * velocity[geneIdx] + (1.0 - config.momentum) * rawStep
                let step = max(-config.maxStepSeconds, min(config.maxStepSeconds, velocity[geneIdx]))

                // Apply the step and clamp to working hours + horizon.
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
                chromosome.genes[geneIdx] = chromosome.genes[geneIdx].withStartTime(newStart)
            }

            // Repair and evaluate after each pass.
            chromosome.repair(context: context)
            evaluate(&chromosome)

            if chromosome.rawFitness > bestFitness {
                best = chromosome
                bestFitness = chromosome.rawFitness
            }
        }

        // Always return the best state seen — gradient refinement is not
        // monotonic under repair noise, so we don't trust the final pass.
        chromosome = best
        return max(0, bestFitness - initialFitness)
    }
}

// MARK: - Softmax Slot Relaxation (Reference)

/// Soft slot-assignment representation used by research into gradient-
/// guided combinatorial search (DARTS, Differentiable Architecture
/// Search). We expose the structure as a helper so future work can plug
/// a real `JAX`/`MLX`-backed learner in without redesigning the archive.
///
/// For now we ship the representation only — no trainable parameters —
/// because a real gradient backend requires tight integration with the
/// fitness evaluator's autograd surface, which Bubo doesn't expose.
struct SoftSlotAssignment: Sendable {
    /// For each event, a probability distribution over candidate slots.
    /// Sum per row is 1.0. Hot-swap to a one-hot at discretize time.
    var logits: [[Double]]

    /// Candidate slot start times, shared across every event.
    let slotStarts: [Date]

    /// Convert logits to a probability matrix via row-wise softmax.
    func probabilities() -> [[Double]] {
        logits.map { row in
            let m = row.max() ?? 0
            let expd = row.map { exp($0 - m) }
            let sum = expd.reduce(0, +)
            guard sum > 0 else { return [Double](repeating: 1.0 / Double(row.count), count: row.count) }
            return expd.map { $0 / sum }
        }
    }

    /// Discretize to one-hot assignments by argmax per event.
    func discretize() -> [Int] {
        logits.map { row in
            var bestIdx = 0
            var bestValue = -Double.infinity
            for (i, v) in row.enumerated() where v > bestValue {
                bestValue = v
                bestIdx = i
            }
            return bestIdx
        }
    }
}
