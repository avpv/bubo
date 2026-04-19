import Foundation

// MARK: - Multi-Fidelity Evaluator (Wave 1 / п.15)
//
// Two-tier evaluation funnel for populations where full objective
// scoring is expensive (14 objectives × conflict graph traversal) and
// the GA mostly just needs a good ranking signal.
//
// Tier 1 — cheap: RBF surrogate prediction on the feature vector. ~0.1
// ms per chromosome. Gives an approximate fitness.
//
// Tier 2 — full: the existing `FitnessEvaluator.evaluateAndAssign`.
// ~1–10 ms per chromosome on a 30-event workload.
//
// The funnel runs tier 1 on every candidate and picks the top K by
// surrogate score to promote to tier 2. Everything else keeps its
// surrogate-predicted fitness. This preserves the GA's convergence
// behaviour while cutting total CPU 40–60% in the typical case where
// 80% of each generation's offspring are non-elite.
//
// The existing `surrogateAssistedEvaluator` in `BuboOptimizer` is a
// *per-chromosome* screen (accept OR real-eval). This funnel is a
// *batch* screen (rank-then-promote). Both can coexist — the funnel
// skips any chromosome that's already evaluated, so a surrogate-
// accepted individual goes through without a second look.

/// Drop-in replacement for the per-chromosome evaluator closure used
/// by the island GA, implementing a tier-1/tier-2 funnel.
///
/// Usage: call `evaluateBatch(...)` once per generation with the full
/// candidate pool (offspring + elites). Individuals without a
/// surrogate-trained basis still go straight to tier 2 (warm-up),
/// so the funnel costs nothing until the surrogate is trained.
final class MultiFidelityEvaluator: @unchecked Sendable {
    struct Configuration: Sendable {
        /// Fraction of the batch promoted to full evaluation every call.
        /// 0.0 = everyone gets surrogate scores, 1.0 = funnel is off.
        /// Default 0.25 matches the usual elite+near-elite share that
        /// benefits from precise scoring; lower values risk surrogate
        /// drift, higher values defeat the point of tiering.
        let tier2FractionPromoted: Double

        /// Guarantee at least this many chromosomes go to tier 2 per
        /// batch — protects tiny batches and the first few generations
        /// from being surrogate-only.
        let tier2MinimumPromoted: Int

        /// When the surrogate's rolling MAE exceeds this threshold,
        /// the funnel disables itself for one call and sends every
        /// candidate to tier 2. Lets the surrogate retrain.
        let maeSafetyThreshold: Double

        /// Noise added to surrogate predictions when tier 2 picks its
        /// promotion list. Prevents the funnel from always promoting
        /// the same chromosomes (which would turn it into vanilla
        /// top-K elitism and starve exploration). Uniform in
        /// `[-noise, noise]` as a fraction of the fitness range.
        let predictionNoise: Double

        static let `default` = Configuration(
            tier2FractionPromoted: 0.25,
            tier2MinimumPromoted: 4,
            maeSafetyThreshold: 0.12,
            predictionNoise: 0.01
        )
    }

    let config: Configuration
    let surrogate: RBFSurrogate
    let evaluator: FitnessEvaluator

    private let lock = NSLock()
    private var batchesRun: Int = 0
    private var tier1Served: Int = 0
    private var tier2Served: Int = 0

    init(
        surrogate: RBFSurrogate,
        evaluator: FitnessEvaluator,
        config: Configuration = .default
    ) {
        self.surrogate = surrogate
        self.evaluator = evaluator
        self.config = config
    }

    /// Evaluate an entire batch of chromosomes with multi-fidelity
    /// screening. Mutates `chromosomes` in place, assigning fitness.
    /// Returns a small telemetry record for optional logging.
    @discardableResult
    func evaluateBatch(
        _ chromosomes: inout [ScheduleChromosome],
        context: OptimizerContext
    ) -> BatchResult {
        guard !chromosomes.isEmpty else { return BatchResult(tier1: 0, tier2: 0, skipped: 0) }

        let mae = surrogate.telemetry.rollingMAE
        let mustFullEvaluate = mae >= config.maeSafetyThreshold

        // Pre-filter: already-evaluated individuals need no work.
        // They still participate in the "top K" ranking so the
        // funnel doesn't starve them.
        var indicesToScore: [Int] = []
        indicesToScore.reserveCapacity(chromosomes.count)
        for i in chromosomes.indices where chromosomes[i].needsEvaluation {
            indicesToScore.append(i)
        }

        guard !indicesToScore.isEmpty else {
            return BatchResult(tier1: 0, tier2: 0, skipped: chromosomes.count)
        }

        // Tier 1: surrogate predictions on every unscored chromosome.
        // We don't write to the chromosome yet — writing prematurely
        // would block the subsequent tier-2 full evaluation, which
        // short-circuits on `needsEvaluation == false`.
        struct ScreenResult {
            var score: Double
            var predictedFitness: Double
            var predictedObjectives: ContiguousArray<Double>?
            var lowConfidence: Bool
        }
        var surrogateScores = [Int: ScreenResult]()
        surrogateScores.reserveCapacity(indicesToScore.count)

        let noise = config.predictionNoise
        let rng = context.rng

        for i in indicesToScore {
            let features = ScheduleFeatureVector.extractOrCache(
                &chromosomes[i],
                context: context
            ).values
            let decision = surrogate.screen(features: features)
            switch decision {
            case .accept(let predictedFitness, let predictedObjectives):
                let jitter = noise > 0 ? rng.double(in: -noise...noise) : 0
                surrogateScores[i] = ScreenResult(
                    score: predictedFitness + jitter,
                    predictedFitness: predictedFitness,
                    predictedObjectives: predictedObjectives,
                    lowConfidence: false
                )
            case .realEvaluate(_, let prior):
                // Surrogate says it's not confident — should go to
                // tier 2 regardless of the ranking. Mark as high
                // priority so ranking pulls it in.
                surrogateScores[i] = ScreenResult(
                    score: Double.infinity,
                    predictedFitness: prior ?? 0,
                    predictedObjectives: nil,
                    lowConfidence: true
                )
            }
        }

        // Tier 2 promotion: top K by surrogate score. Already-hot
        // indices (lowConfidence on surrogate) were marked with
        // +Infinity so they rank first and always promote.
        let k = max(
            config.tier2MinimumPromoted,
            Int((Double(indicesToScore.count) * config.tier2FractionPromoted).rounded(.up))
        )
        let promotions: Set<Int>
        if mustFullEvaluate {
            promotions = Set(indicesToScore)
        } else {
            let ranked = indicesToScore.sorted { a, b in
                (surrogateScores[a]?.score ?? 0) > (surrogateScores[b]?.score ?? 0)
            }
            promotions = Set(ranked.prefix(k))
        }

        var tier1Count = 0
        var tier2Count = 0

        for i in indicesToScore {
            if promotions.contains(i) {
                // Tier 2: full evaluation. Note it records back to
                // the surrogate, keeping the model calibrated.
                let screen = surrogateScores[i]
                let hadPrediction = screen.map { !$0.lowConfidence } ?? false
                evaluator.evaluateAndAssign(&chromosomes[i], context: context)
                if hadPrediction, let screen {
                    let features = ScheduleFeatureVector.extractOrCache(
                        &chromosomes[i],
                        context: context
                    ).values
                    let objectivesVec = assembleObjectiveVector(
                        cache: chromosomes[i].objectiveCache,
                        evaluator: evaluator
                    )
                    surrogate.record(
                        features: features,
                        fitness: chromosomes[i].rawFitness,
                        objectives: objectivesVec,
                        priorPrediction: screen.predictedFitness
                    )
                }
                tier2Count += 1
            } else if let screen = surrogateScores[i], !mustFullEvaluate {
                // Tier 1: trust the surrogate's prediction. Only
                // applies to confident accepts — lowConfidence
                // results fell through to tier 2 via promotion.
                chromosomes[i].fitness = screen.predictedFitness
                chromosomes[i].rawFitness = screen.predictedFitness
                chromosomes[i].needsEvaluation = false
                if let vec = screen.predictedObjectives {
                    chromosomes[i].objectiveCache = assembleObjectiveCache(
                        from: vec, evaluator: evaluator
                    )
                }
                tier1Count += 1
            } else {
                tier1Count += 1
            }
        }

        lock.lock()
        batchesRun += 1
        tier1Served += tier1Count
        tier2Served += tier2Count
        lock.unlock()

        return BatchResult(
            tier1: tier1Count,
            tier2: tier2Count,
            skipped: chromosomes.count - indicesToScore.count
        )
    }

    /// Per-batch result for logging. Plain value, cheap to construct.
    struct BatchResult: Sendable {
        let tier1: Int
        let tier2: Int
        let skipped: Int
    }

    /// Running telemetry. Useful for deciding whether the funnel is
    /// worth keeping on — if tier1:tier2 ratio never exceeds 1.5,
    /// the surrogate isn't trained well enough and the host should
    /// disable the funnel.
    struct Telemetry: Sendable {
        let batchesRun: Int
        let tier1Served: Int
        let tier2Served: Int
        let tier1Ratio: Double
    }

    var telemetry: Telemetry {
        lock.lock(); defer { lock.unlock() }
        let total = tier1Served + tier2Served
        let ratio = total > 0 ? Double(tier1Served) / Double(total) : 0
        return Telemetry(
            batchesRun: batchesRun,
            tier1Served: tier1Served,
            tier2Served: tier2Served,
            tier1Ratio: ratio
        )
    }

    // MARK: - Helpers

    private func assembleObjectiveCache(
        from vec: ContiguousArray<Double>,
        evaluator: FitnessEvaluator
    ) -> [String: Double] {
        var cache: [String: Double] = [:]
        cache.reserveCapacity(evaluator.objectives.count)
        let count = min(vec.count, evaluator.objectives.count)
        for i in 0..<count {
            cache[evaluator.objectives[i].name] = vec[i]
        }
        return cache
    }

    private func assembleObjectiveVector(
        cache: [String: Double]?,
        evaluator: FitnessEvaluator
    ) -> ContiguousArray<Double>? {
        guard let cache else { return nil }
        var v = ContiguousArray<Double>()
        v.reserveCapacity(evaluator.objectives.count)
        for obj in evaluator.objectives {
            v.append(cache[obj.name] ?? 0)
        }
        return v
    }
}
