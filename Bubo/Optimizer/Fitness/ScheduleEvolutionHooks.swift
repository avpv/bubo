import Foundation

// MARK: - Schedule-Specific Evolution Hooks
//
// Concrete `EvolutionHooks<ScheduleChromosome>` instances that wire
// schedule-specific features (Quality-Diversity archive feeding and
// emission, gradient refinement) into the generic `GeneticAlgorithm`
// without leaking `ScheduleChromosome` into the engine. The host
// (`BuboOptimizer`) composes the hooks it wants and passes a single
// combined bundle to `IslandModelGA`.

enum ScheduleEvolutionHooks {

    /// Feed every newly-evaluated offspring into a `QualityDiversityArchive`.
    /// Single-pass — descriptor extraction is cheap (~µs per chromosome)
    /// because it reads the unified `ScheduleFeatureVector`.
    static func qualityDiversityFeeding(
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
    static func qualityDiversityEmission(
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
    static func gradientRefinement(
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

    /// Combine multiple schedule hook bundles. Convenience wrapper over
    /// the generic `EvolutionHooks.combine` so the caller can write
    /// `ScheduleEvolutionHooks.compose(.qualityDiversityFeeding(...), .gradientRefinement(...))`.
    static func compose(
        _ hooks: EvolutionHooks<ScheduleChromosome>...
    ) -> EvolutionHooks<ScheduleChromosome> {
        hooks.reduce(.noop) { EvolutionHooks.combine($0, $1) }
    }

    // MARK: - Internals

    /// Replace the worst non-elite individuals with archive emitters.
    /// Eliter slots are left untouched. Emitters are inserted as-is —
    /// their fitness carries over from the archive (real-evaluated at
    /// insertion time), so no re-evaluation runs here.
    private static func injectEmitters(
        _ emitters: [ScheduleChromosome],
        into population: inout Population<ScheduleChromosome>
    ) {
        let eliteCount = population.eliteCount
        let n = population.individuals.count
        guard n > eliteCount else { return }

        // Worst-first ordering of replaceable slots.
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
