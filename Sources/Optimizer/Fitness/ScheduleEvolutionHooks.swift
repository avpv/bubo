import Foundation

// MARK: - Schedule-Specific Evolution Hooks
//
// Concrete `EvolutionHooks<ScheduleChromosome>` instances that wire
// schedule-specific features (Quality-Diversity archive feeding and
// emission, gradient refinement) into the generic `GeneticAlgorithm`
// without leaking `ScheduleChromosome` into the engine. The host
// (`BuboOptimizer`) composes the hooks it wants and passes a single
// combined bundle to `IslandModelGA`.

public enum ScheduleEvolutionHooks {

    /// Feed every newly-evaluated offspring into a `QualityDiversityArchive`.
    /// Single-pass — descriptor extraction is cheap (~µs per chromosome)
    /// because it reads the unified `ScheduleFeatureVector`.
    public static func qualityDiversityFeeding(
        archive: QualityDiversityArchive
    ) -> EvolutionHooks<ScheduleChromosome> {
        EvolutionHooks<ScheduleChromosome>(
            onOffspringEvaluated: { _, offspring, context in
                archive.tick()
                for chromosome in offspring {
                    let descriptor = BehaviorDescriptor.from(chromosome, context: context)
                    archive.consider(chromosome, descriptor: descriptor)
                }
            },
            onGenerationComplete: nil,
            onPostEvolution: nil
        )
    }

    /// Inject archive incumbents into the population every generation.
    /// `emissionRate` controls what fraction of the population is
    /// replaced; 0 disables. Replacements skip elites so the current
    /// champion is never displaced.
    ///
    /// Re-evaluation is `nil` because emitters carry their original
    /// fitness from the archive — they were *real* evaluations
    /// historically, just inserted at a different generation.
    public static func qualityDiversityEmission(
        archive: QualityDiversityArchive,
        emissionRate: Double
    ) -> EvolutionHooks<ScheduleChromosome> {
        guard emissionRate > 0 else { return .noop }
        return EvolutionHooks<ScheduleChromosome>(
            onOffspringEvaluated: nil,
            onGenerationComplete: { _, population, context in
                let count = max(1, Int(Double(population.individuals.count) * emissionRate))
                let emitters = archive.drawEmitters(count: count, rng: context.rng)
                guard !emitters.isEmpty else { return }
                injectEmitters(emitters, into: &population)
            },
            onPostEvolution: nil
        )
    }

    /// Run gradient refinement on the top elites every `interval`
    /// generations. The refiner needs an evaluator closure — the
    /// caller passes the same one the GA was constructed with so
    /// fitness values stay consistent.
    public static func gradientRefinement(
        refiner: ScheduleGradientRefiner,
        interval: Int,
        candidates: Int,
        evaluate: @escaping @Sendable (inout ScheduleChromosome) -> Void
    ) -> EvolutionHooks<ScheduleChromosome> {
        guard interval > 0, candidates > 0 else { return .noop }
        return EvolutionHooks<ScheduleChromosome>(
            onOffspringEvaluated: nil,
            onGenerationComplete: { generation, population, context in
                guard generation > 0, generation % interval == 0 else { return }

                let n = population.individuals.count
                guard n > 0 else { return }

                let topIndices = population.individuals.indices
                    .sorted { population.individuals[$0].rawFitness > population.individuals[$1].rawFitness }
                    .prefix(min(candidates, n))

                for idx in topIndices {
                    var chromosome = population.individuals[idx]
                    let delta = refiner.refine(&chromosome, context: context, evaluate: evaluate)
                    if delta > 0 {
                        population.individuals[idx] = chromosome
                    }
                }
            },
            onPostEvolution: nil
        )
    }

    /// Inject CMA-ME emitter children into the population every
    /// generation. Differs from `qualityDiversityEmission` in two
    /// ways: (a) children are freshly *sampled* from a covariance-
    /// adapted Gaussian rather than drawn from the archive, and
    /// (b) success / failure of the batch updates the emitter's
    /// sigma + mean for the next round (1/5 success rule).
    ///
    /// Combine multiple schedule hook bundles. Convenience wrapper over
    /// the generic `EvolutionHooks.combine` so the caller can write
    /// `ScheduleEvolutionHooks.compose(.qualityDiversityFeeding(...), .gradientRefinement(...))`.
    public static func compose(
        _ hooks: EvolutionHooks<ScheduleChromosome>...
    ) -> EvolutionHooks<ScheduleChromosome> {
        hooks.reduce(.noop) { EvolutionHooks.combine($0, $1) }
    }

    /// Array-based overload for the rare caller that builds the hook
    /// list dynamically (e.g. flag-conditional CMA-ME emission).
    public static func compose(
        contentsOf hooks: [EvolutionHooks<ScheduleChromosome>]
    ) -> EvolutionHooks<ScheduleChromosome> {
        hooks.reduce(.noop) { EvolutionHooks.combine($0, $1) }
    }

    // CMA-ME emission hook + its internals were removed along with
    // `CMAMEEmitter`. The uniform MAP-Elites emitter covers the
    // archive-diversity use case on realistic workloads without the
    // per-generation covariance update.

    /// Replace the worst non-elite individuals with archive emitters.
    /// Elite slots are left untouched; emitters carry their archive
    /// fitness so no re-evaluation runs here.
    private static func injectEmitters(
        _ emitters: [ScheduleChromosome],
        into population: inout Population<ScheduleChromosome>
    ) {
        let eliteCount = population.eliteCount
        let n = population.individuals.count
        guard n > eliteCount else { return }

        let sorted = population.individuals.indices.sorted {
            population.individuals[$0].rawFitness > population.individuals[$1].rawFitness
        }
        let replaceable = Array(sorted.suffix(n - eliteCount).reversed())

        var slot = 0
        for emitter in emitters {
            guard slot < replaceable.count else { break }
            population.individuals[replaceable[slot]] = emitter
            slot += 1
        }
    }
}
