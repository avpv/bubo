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

    /// Inject CMA-ME emitter children into the population every
    /// generation. Differs from `qualityDiversityEmission` in two
    /// ways: (a) children are freshly *sampled* from a covariance-
    /// adapted Gaussian rather than drawn from the archive, and
    /// (b) success / failure of the batch updates the emitter's
    /// sigma + mean for the next round (1/5 success rule).
    ///
    /// `templateProvider` returns the chromosome the emitter binds
    /// to — typically the population's current best so the emitter
    /// always perturbs around the front-runner. The new children
    /// must be re-evaluated; the caller passes the same `evaluate`
    /// closure used elsewhere.
    static func cmaMEEmission(
        archive: QualityDiversityArchive,
        emissionRate: Double,
        templateProvider: @escaping @Sendable (Population<ScheduleChromosome>) -> ScheduleChromosome?,
        evaluate: @escaping @Sendable (inout ScheduleChromosome) -> Void
    ) -> EvolutionHooks<ScheduleChromosome> {
        guard emissionRate > 0 else { return .noop }
        // Per-hook lock guards the lazily-bound emitter so concurrent
        // island GAs sharing the hook see consistent sigma/mean.
        let state = CMAMEHookState()
        return EvolutionHooks<ScheduleChromosome>(
            onOffspringEvaluated: nil,
            onGenerationComplete: { _, population, context in
                let count = max(1, Int(Double(population.individuals.count) * emissionRate))
                guard let template = templateProvider(population) else { return }
                let emitter = state.emitter(for: template)
                var batch: [ScheduleChromosome] = []
                batch.reserveCapacity(count)
                for _ in 0..<count {
                    var child = emitter.emit(context: context)
                    evaluate(&child)
                    batch.append(child)
                }
                // Archive deposit + adaptive update.
                var successful = 0
                var improvementDirections: [[Double]] = []
                let cal = context.calendar
                for child in batch {
                    let descriptor = BehaviorDescriptor.from(child, context: context)
                    let outcome = archive.consider(child, descriptor: descriptor)
                    if outcome.inserted {
                        successful += 1
                        // Capture per-gene minute deltas — used by the
                        // emitter's mean update to drift toward the
                        // improving direction.
                        var dir: [Double] = []
                        dir.reserveCapacity(template.genes.count)
                        for (i, gene) in child.genes.enumerated() where i < template.genes.count {
                            let baseline = template.genes[i].startTime
                            let minutes = gene.startTime.timeIntervalSince(baseline) / 60
                            dir.append(minutes)
                        }
                        _ = cal
                        improvementDirections.append(dir)
                    }
                }
                emitter.observe(
                    successCount: successful,
                    totalSamples: batch.count,
                    improvementDirections: improvementDirections
                )
                if emitter.hasConverged {
                    state.invalidate()
                }
                injectEmitters(batch, into: &population)
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

    /// Array-based overload for the rare caller that builds the hook
    /// list dynamically (e.g. flag-conditional CMA-ME emission).
    static func compose(
        contentsOf hooks: [EvolutionHooks<ScheduleChromosome>]
    ) -> EvolutionHooks<ScheduleChromosome> {
        hooks.reduce(.noop) { EvolutionHooks.combine($0, $1) }
    }

    // MARK: - Internals

    /// Replace the worst non-elite individuals with archive emitters.
    /// Eliter slots are left untouched. Emitters are inserted as-is —
    /// their fitness carries over from the archive (real-evaluated at
    /// insertion time), so no re-evaluation runs here.
    /// Per-hook state for the CMA-ME emission path. Holds a lazily-
    /// constructed emitter bound to a template chromosome and lets
    /// the hook invalidate it when the emitter converges so the next
    /// generation rebinds to a fresher front-runner.
    fileprivate final class CMAMEHookState: @unchecked Sendable {
        private let lock = NSLock()
        private var bound: CMAMEEmitter?
        private var templateHash: Int?

        func emitter(for template: ScheduleChromosome) -> CMAMEEmitter {
            lock.lock()
            defer { lock.unlock() }
            // Rebind when the template changed; cheap fingerprint
            // by gene count + first/last startTime.
            let hash = stableTemplateHash(template)
            if let bound, templateHash == hash {
                return bound
            }
            let fresh = CMAMEEmitter(template: template)
            self.bound = fresh
            self.templateHash = hash
            return fresh
        }

        func invalidate() {
            lock.lock()
            defer { lock.unlock() }
            bound = nil
            templateHash = nil
        }

        private func stableTemplateHash(_ template: ScheduleChromosome) -> Int {
            var hasher = Hasher()
            hasher.combine(template.genes.count)
            if let first = template.genes.first {
                hasher.combine(first.eventId)
                hasher.combine(first.startTime.timeIntervalSinceReferenceDate.rounded())
            }
            if let last = template.genes.last {
                hasher.combine(last.eventId)
                hasher.combine(last.startTime.timeIntervalSinceReferenceDate.rounded())
            }
            return hasher.finalize()
        }
    }

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
