import Foundation

// MARK: - Synthetic Preference Pair Generator
//
// Bootstraps the DPO + calendar-embedder trainers before real user
// feedback is available by generating (winner, loser) pairs from
// the evaluator's own judgement. The method:
//
//   1. Sample a seed chromosome (greedy or random).
//   2. Create K perturbed variants via a sequence of mutations.
//   3. Score all variants with the configured evaluator.
//   4. Pair the top variant (winner) against bottom variants (loser)
//      — N choose 2 pairs discarded, we keep top-vs-bottom for a
//      strong gradient signal.
//
// The generator is deliberately frugal: it uses the *current* GA
// operators and the *current* FitnessEvaluator, so any improvement
// to the evaluator automatically raises the quality of synthetic
// training data. The output preference source is tagged `.synthetic`
// so downstream trainers can optionally weight synthetic pairs less
// than real user feedback.

public struct SyntheticPairGenerationResult: Sendable {

    public init(
        pairs: [PreferencePairEvent],
        variantsSampled: Int,
        rejectedByNoise: Int
    ) {
        self.pairs = pairs
        self.variantsSampled = variantsSampled
        self.rejectedByNoise = rejectedByNoise
    }

    public let pairs: [PreferencePairEvent]
    public let variantsSampled: Int
    public let rejectedByNoise: Int
}

public enum SyntheticPreferencePairGenerator {
    public struct Configuration: Sendable {

        public init(
            variantsPerSeed: Int,
            seedCount: Int,
            winnerCutoff: Double,
            minFitnessGap: Double,
            perturbationRate: Double,
            pairsPerSeed: Int
        ) {
            self.variantsPerSeed = variantsPerSeed
            self.seedCount = seedCount
            self.winnerCutoff = winnerCutoff
            self.minFitnessGap = minFitnessGap
            self.perturbationRate = perturbationRate
            self.pairsPerSeed = pairsPerSeed
        }

        /// Number of perturbed variants to draw per seed.
        let variantsPerSeed: Int
        /// Number of seeds to evaluate per call.
        let seedCount: Int
        /// Ratio in [0, 1]: how many of the variants form winner
        /// candidates. `0.5` = top half is eligible winners.
        let winnerCutoff: Double
        /// Minimum fitness gap between winner and loser. Prevents
        /// near-tie pairs from injecting noise.
        let minFitnessGap: Double
        /// Mutation rate used when perturbing the seed. Higher = more
        /// diverse variants, lower = more focused exploration.
        let perturbationRate: Double
        /// How many pairs to emit per seed (capped at `variantsPerSeed * winnerCutoff`).
        let pairsPerSeed: Int

        static let `default` = Configuration(
            variantsPerSeed: 12,
            seedCount: 3,
            winnerCutoff: 0.3,
            minFitnessGap: 0.05,
            perturbationRate: 0.25,
            pairsPerSeed: 4
        )
    }

    /// Produce synthetic pairs for the given context. Thread-safe —
    /// takes everything it needs by value and doesn't mutate the
    /// evaluator beyond its own internal caches.
    public static func generate(
        context: OptimizerContext,
        evaluator: FitnessEvaluator,
        config: Configuration = .default
    ) -> SyntheticPairGenerationResult {
        var pairs: [PreferencePairEvent] = []
        var variantsSampled = 0
        var rejected = 0

        for _ in 0..<config.seedCount {
            let seed = ScheduleChromosome.greedy(context: context)
            var variants: [ScheduleChromosome] = []
            variants.reserveCapacity(config.variantsPerSeed)
            for _ in 0..<config.variantsPerSeed {
                var clone = seed
                clone.mutate(rate: config.perturbationRate, context: context)
                clone.repair(context: context)
                evaluator.evaluateAndAssign(&clone, context: context)
                variantsSampled += 1
                variants.append(clone)
            }
            variants.sort { $0.rawFitness > $1.rawFitness }
            let cutoff = max(1, Int(Double(variants.count) * config.winnerCutoff))
            let winners = Array(variants.prefix(cutoff))
            let losers = Array(variants.suffix(cutoff))

            // Cross-product until pairsPerSeed.
            var emittedForSeed = 0
            for w in winners {
                if emittedForSeed >= config.pairsPerSeed { break }
                for l in losers {
                    if emittedForSeed >= config.pairsPerSeed { break }
                    if w.rawFitness - l.rawFitness < config.minFitnessGap {
                        rejected += 1
                        continue
                    }
                    let wScores = evaluator.objectiveBreakdown(for: w, context: context)
                    let lScores = evaluator.objectiveBreakdown(for: l, context: context)
                    pairs.append(PreferencePairEvent(
                        timestamp: Date(),
                        winnerScores: wScores,
                        loserScores: lScores,
                        confidence: 0.5,   // synthetic is half-weight
                        source: .synthetic
                    ))
                    emittedForSeed += 1
                }
            }
        }

        return SyntheticPairGenerationResult(
            pairs: pairs,
            variantsSampled: variantsSampled,
            rejectedByNoise: rejected
        )
    }
}
