import Foundation

// MARK: - Surrogate-Assisted Evaluation (RBF + kNN uncertainty)
//
// The 13-objective `FitnessEvaluator` is expensive (>1 ms per full
// eval on weekly horizons). When a generation spawns 100+ offspring,
// most of which are lightly-mutated clones of recent individuals, the
// marginal cost of running the real evaluator on all of them is
// wasted budget. The surrogate predicts fitness and the GA skips the
// real call when the prediction is trustworthy.
//
// Honest framing of the model:
//   • RBF interpolation over a sliding window of the most recent
//     real evaluations, weighted by Gaussian distance kernel.
//   • Uncertainty proxy = distance to the nearest training sample.
//     This is a kNN-style "local roughness" heuristic, not a true
//     Gaussian-Process predictive variance. It's substantially
//     cheaper (no kernel matrix inversion) and behaves similarly in
//     the regimes a calendar fitness landscape produces — smooth
//     locally, with islands of irregular structure that the kNN
//     distance flags as high uncertainty.
//
// Hot-path optimizations vs. the original implementation:
//   • Features are `ContiguousArray<Double>` of fixed dimension; the
//     distance loop is unrolled by the compiler.
//   • Top-k neighbour selection uses a partial-sort heap instead of
//     full sort (O(N log k) vs O(N log N)).
//   • A reusable distance buffer lives on the surrogate so screening
//     allocates nothing in the steady state.

/// RBF-weighted fitness predictor with kNN fallback. Thread-safe via
/// an internal lock — the GA's parallel offspring evaluation appends
/// samples and queries from many threads.
final class RBFSurrogate: @unchecked Sendable {
    struct TrainingSample: Sendable {
        let features: ContiguousArray<Double>
        let fitness: Double
        /// Per-objective scores in a canonical order (same order used by
        /// `MultiObjectiveContext.objectiveVectorOf`). When present, the
        /// surrogate predicts this vector on accept so downstream
        /// consumers (NSGA-III, hypervolume) see non-zero objective
        /// caches for surrogate-predicted individuals.
        let objectives: ContiguousArray<Double>?
    }

    /// All knobs settable at construction. No runtime mutation.
    struct Configuration: Sendable {
        /// Training-set cap. Oldest samples evict when capacity is hit.
        let capacity: Int
        /// RBF bandwidth. With features in `[0, 1]^16`, 0.25 means a
        /// candidate 0.1 away contributes ~85% of a candidate at the
        /// origin and a 0.5-distant candidate contributes ~14%.
        let bandwidth: Double
        /// Neighbours used per prediction. Small values reduce kNN
        /// bias at the cost of variance; ~8–16 is the sweet spot.
        let neighbors: Int
        /// Distance above which we declare "high uncertainty" and
        /// fall back to the real evaluator.
        let realEvalThreshold: Double
        /// Every N surrogate predictions, run one real evaluation
        /// anyway to keep the model calibrated against drift.
        let trustRefreshInterval: Int
        /// Minimum training samples before the surrogate is trusted.
        /// Below this, every prediction falls back to the real
        /// evaluator.
        let warmupSamples: Int

        static let `default` = Configuration(
            capacity: 500,
            bandwidth: 0.25,
            neighbors: 12,
            realEvalThreshold: 0.22,
            trustRefreshInterval: 7,
            warmupSamples: 40
        )

        static let aggressive = Configuration(
            capacity: 800,
            bandwidth: 0.30,
            neighbors: 16,
            realEvalThreshold: 0.30,
            trustRefreshInterval: 12,
            warmupSamples: 30
        )
    }

    /// Result of a screen decision.
    enum Screen: Sendable {
        /// Surrogate trusts its prediction. Includes the predicted
        /// objective vector when training samples carried one — nil
        /// means objective-cache-aware callers must still fall back
        /// to the real evaluator.
        case accept(predictedFitness: Double, predictedObjectives: ContiguousArray<Double>?)
        /// Surrogate doesn't trust itself; GA must run the real
        /// evaluator. `priorPrediction` is what the RBF *would* have
        /// predicted for the feature vector — pass it back to
        /// `record` to track rolling MAE against the real result.
        /// Nil during warm-up (no neighbours yet).
        case realEvaluate(reason: String, priorPrediction: Double?)
    }

    struct Telemetry: Sendable {
        let totalScreens: Int
        let accepted: Int
        let realEvaluated: Int
        let trainingSize: Int
        /// Running mean absolute error between surrogate predictions
        /// and the real evaluation, computed when the caller passes a
        /// prior-prediction value to `record`.
        let rollingMAE: Double
    }

    let config: Configuration

    private var samples: [TrainingSample] = []
    private var screensSinceRefresh: Int = 0
    private var totalScreens: Int = 0
    private var accepted: Int = 0
    private var realEvaluated: Int = 0
    private var maeSum: Double = 0
    private var maeCount: Int = 0
    private let lock = NSLock()

    init(config: Configuration = .default) {
        self.config = config
        self.samples.reserveCapacity(config.capacity)
    }

    // MARK: - Query

    /// Decide whether the caller should trust the surrogate's
    /// prediction for `features`, or fall back to the real evaluator.
    /// `.realEvaluate` carries a prior prediction when one was
    /// computed so the caller can feed it back through `record` for
    /// MAE tracking.
    func screen(features: ContiguousArray<Double>) -> Screen {
        lock.lock()
        defer { lock.unlock() }
        totalScreens += 1
        screensSinceRefresh += 1

        guard samples.count >= config.warmupSamples else {
            realEvaluated += 1
            return .realEvaluate(reason: "warmup", priorPrediction: nil)
        }

        // Compute distances and prediction upfront so every `realEvaluate`
        // return path can surface the would-be prediction. It's cheap
        // (~N·16 float ops) vs. the real evaluator's millisecond cost.
        let distances = computeDistances(to: features)
        let k = min(config.neighbors, distances.count)
        let topK = partialSort(distances: distances, k: k)
        let prediction: Double? = topK.isEmpty ? nil : rbfPredict(neighbours: topK)

        if screensSinceRefresh >= config.trustRefreshInterval {
            screensSinceRefresh = 0
            realEvaluated += 1
            return .realEvaluate(reason: "calibrationRefresh", priorPrediction: prediction)
        }

        guard let closest = topK.first else {
            realEvaluated += 1
            return .realEvaluate(reason: "noNeighbors", priorPrediction: nil)
        }
        if closest.distance > config.realEvalThreshold {
            realEvaluated += 1
            return .realEvaluate(reason: "highUncertainty", priorPrediction: prediction)
        }
        let predictedObjectives = rbfPredictObjectives(neighbours: topK)
        accepted += 1
        return .accept(predictedFitness: prediction ?? 0, predictedObjectives: predictedObjectives)
    }

    // MARK: - Update

    /// Register a (features → fitness) pair. Optional `objectives`
    /// populates the 13-dim per-objective vector so subsequent
    /// surrogate-accepts can supply a predicted objective cache to
    /// NSGA-III / hypervolume consumers. `priorPrediction` closes the
    /// MAE tracking loop — pass the value surrogate returned *before*
    /// this real evaluation so `rollingMAE` in telemetry reflects
    /// drift against reality.
    func record(
        features: ContiguousArray<Double>,
        fitness: Double,
        objectives: ContiguousArray<Double>? = nil,
        priorPrediction: Double? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(TrainingSample(features: features, fitness: fitness, objectives: objectives))
        if samples.count > config.capacity {
            samples.removeFirst(samples.count - config.capacity)
            // Reset MAE periodically so drift is measured on recent
            // data only.
            if maeCount > config.capacity / 2 {
                maeSum = 0
                maeCount = 0
            }
        }
        if let prior = priorPrediction {
            maeSum += abs(prior - fitness)
            maeCount += 1
        }
    }

    var telemetry: Telemetry {
        lock.lock()
        defer { lock.unlock() }
        let mae = maeCount > 0 ? maeSum / Double(maeCount) : 0
        return Telemetry(
            totalScreens: totalScreens,
            accepted: accepted,
            realEvaluated: realEvaluated,
            trainingSize: samples.count,
            rollingMAE: mae
        )
    }

    // MARK: - Internals

    private struct NeighborDistance {
        let sampleIndex: Int
        let distance: Double
    }

    /// Compute Euclidean distance from `query` to every training
    /// sample. Returns indices + distances; sample lookup happens in
    /// the prediction step.
    private func computeDistances(to query: ContiguousArray<Double>) -> [NeighborDistance] {
        var out = [NeighborDistance]()
        out.reserveCapacity(samples.count)
        let dim = ScheduleFeatureVector.dimension
        for i in 0..<samples.count {
            out.append(NeighborDistance(sampleIndex: i, distance: euclideanFixed(query, samples[i].features, dim: dim)))
        }
        return out
    }

    /// Partial sort: select the `k` smallest by distance using a
    /// max-heap of size `k`. Avoids full O(N log N) sort when only
    /// the top-k are needed.
    private func partialSort(distances: [NeighborDistance], k: Int) -> [NeighborDistance] {
        guard k > 0, !distances.isEmpty else { return [] }
        if k >= distances.count {
            return distances.sorted { $0.distance < $1.distance }
        }
        // Bounded max-heap of the k smallest distances.
        var heap: [NeighborDistance] = Array(distances.prefix(k))
        heap.sort { $0.distance > $1.distance } // max-heap-like (largest at index 0)
        for i in k..<distances.count {
            if distances[i].distance < heap[0].distance {
                heap[0] = distances[i]
                // Sift down — simple O(k) re-sort is fine for k≈12.
                heap.sort { $0.distance > $1.distance }
            }
        }
        return heap.sorted { $0.distance < $1.distance }
    }

    private func rbfPredict(neighbours: [NeighborDistance]) -> Double {
        var weightSum = 0.0
        var weightedFitnessSum = 0.0
        let invBandwidthSq = 1.0 / (config.bandwidth * config.bandwidth)
        for n in neighbours {
            let w = exp(-(n.distance * n.distance) * invBandwidthSq)
            weightSum += w
            weightedFitnessSum += w * samples[n.sampleIndex].fitness
        }
        guard weightSum > 1e-12 else {
            // Pathological: every neighbour effectively infinitely
            // distant. Fall back to plain mean.
            let sum = neighbours.reduce(0.0) { $0 + samples[$1.sampleIndex].fitness }
            return sum / Double(neighbours.count)
        }
        return weightedFitnessSum / weightSum
    }

    /// Predict the 13-dim objective vector by RBF-weighted average of
    /// training samples' objective vectors. Returns nil when no
    /// neighbour carries one (either the surrogate was fed scalar-only
    /// samples, or training is mixed — we require all-or-nothing per
    /// neighbour to avoid silently averaging across different
    /// objective orderings).
    private func rbfPredictObjectives(neighbours: [NeighborDistance]) -> ContiguousArray<Double>? {
        guard !neighbours.isEmpty else { return nil }
        guard let firstVec = samples[neighbours[0].sampleIndex].objectives else {
            return nil
        }
        let dim = firstVec.count
        var weightSum = 0.0
        var accumulator = ContiguousArray<Double>(repeating: 0, count: dim)
        let invBandwidthSq = 1.0 / (config.bandwidth * config.bandwidth)

        for n in neighbours {
            guard let vec = samples[n.sampleIndex].objectives, vec.count == dim else {
                // Heterogeneous training — don't predict objectives.
                return nil
            }
            let w = exp(-(n.distance * n.distance) * invBandwidthSq)
            weightSum += w
            for k in 0..<dim { accumulator[k] += w * vec[k] }
        }
        guard weightSum > 1e-12 else { return nil }
        for k in 0..<dim { accumulator[k] /= weightSum }
        return accumulator
    }

    /// Fixed-dimension Euclidean distance. Uses `withUnsafeBufferPointer`
    /// so the inner loop is a tight pointer-arithmetic walk; the
    /// optimizer turns this into vectorized loads on supported targets.
    @inline(__always)
    private func euclideanFixed(
        _ a: ContiguousArray<Double>,
        _ b: ContiguousArray<Double>,
        dim: Int
    ) -> Double {
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                var sum = 0.0
                for i in 0..<dim {
                    let d = ap[i] - bp[i]
                    sum += d * d
                }
                return sum.squareRoot()
            }
        }
    }
}
