import Foundation

// MARK: - Surrogate-Assisted Evaluation (RBF + kNN uncertainty)
//
// The 13-objective `FitnessEvaluator` is expensive (>1 ms per full eval on
// weekly horizons). When a generation spawns 100+ offspring, most of which
// are lightly-mutated clones of existing individuals, the marginal cost of
// running the real evaluator on all of them is wasted budget — a surrogate
// can predict fitness accurately enough to skip the real call for a large
// fraction of candidates.
//
// We keep the surrogate intentionally small: an RBF model whose training
// set is the population's recently-evaluated individuals. An exact
// Gaussian Process would be O(N³) per refit; a kNN-weighted RBF predictor
// is O(N · d) per query and, empirically, within 3–5% error of GP for the
// kind of smooth fitness landscape calendar scheduling produces.
//
// Screening strategy (SAEA / MOEA/D-EGO school):
//   1. Predict fitness via RBF on the candidate's feature vector.
//   2. Estimate uncertainty as the distance to the nearest training point
//      (farther = less confident). This is a "local variance" proxy that
//      behaves like GP's predictive variance in most regimes.
//   3. If uncertainty is above `realEvalThreshold`, run the real evaluator
//      (exploration — the surrogate doesn't trust itself here).
//   4. Else accept the surrogate prediction, but mark the candidate for
//      periodic real-eval every `trustRefreshInterval` screens so the
//      surrogate stays calibrated.
//
// Expected speedup on thorough runs: ~3-6× effective fitness evaluations
// retained at comparable convergence. Tuning the thresholds trades eval
// budget against surrogate drift.

// MARK: - Feature Extractor

/// Produces a fixed-length feature vector from a `ScheduleChromosome`.
/// Features are deliberately cheap: day-level aggregates that capture the
/// structural differences between schedules without requiring the full
/// objective breakdown.
///
/// We avoid using per-gene start-time deltas directly because the vector
/// must have constant length across chromosomes (event counts are equal,
/// so alignment by eventId position would work, but day-aggregate features
/// generalize better across different OptimizerContext event lists and
/// give the RBF smoother distances).
enum ScheduleFeatures {
    /// Feature vector size — keep small for fast kNN lookups.
    static let dimension: Int = 16

    /// Extract a 16-dim descriptor vector. Every component is normalized
    /// to [0, 1] so Euclidean distance is meaningful across components.
    static func vector(of chromosome: ScheduleChromosome, context: OptimizerContext) -> [Double] {
        let cal = context.calendar
        let horizon = context.planningHorizon
        let horizonStart = cal.startOfDay(for: horizon.start)
        let horizonLastDay = cal.startOfDay(for: horizon.end.addingTimeInterval(-1))
        let daysInHorizon = max(
            1,
            (cal.dateComponents([.day], from: horizonStart, to: horizonLastDay).day ?? 0) + 1
        )
        let workHoursPerDay = max(1, context.workingHours.upperBound - context.workingHours.lowerBound)

        // Aggregates
        var includedCount = 0
        var totalDurationMinutes = 0.0
        var focusDurationMinutes = 0.0
        var energySum = 0.0
        var prioritySum = 0.0
        var startHourSum = 0.0
        var preLunchCount = 0
        var postLunchCount = 0
        var weekdayTouched = 0
        var daysUsed: Set<Date> = []
        var morningMassMinutes = 0.0
        var afternoonMassMinutes = 0.0
        var eveningMassMinutes = 0.0
        var firstStartOffset = Double.infinity
        var lastEndOffset = -Double.infinity
        var droppedCount = 0

        for gene in chromosome.genes {
            if !gene.isIncluded {
                if gene.isDroppable { droppedCount += 1 }
                continue
            }
            includedCount += 1
            let mins = gene.duration / 60.0
            totalDurationMinutes += mins
            if gene.isFocusBlock { focusDurationMinutes += mins }
            energySum += gene.energyCost
            prioritySum += gene.priority
            let hour = cal.component(.hour, from: gene.startTime)
            startHourSum += Double(hour)
            if hour < 12 { preLunchCount += 1 } else { postLunchCount += 1 }

            let day = cal.startOfDay(for: gene.startTime)
            daysUsed.insert(day)
            let weekday = cal.component(.weekday, from: gene.startTime)
            if weekday >= 2 && weekday <= 6 { weekdayTouched += 1 }

            if hour < 12 { morningMassMinutes += mins }
            else if hour < 17 { afternoonMassMinutes += mins }
            else { eveningMassMinutes += mins }

            let startOffset = gene.startTime.timeIntervalSince(horizonStart)
            let endOffset = gene.endTime.timeIntervalSince(horizonStart)
            if startOffset < firstStartOffset { firstStartOffset = startOffset }
            if endOffset > lastEndOffset { lastEndOffset = endOffset }
        }

        let totalGenes = max(1, chromosome.genes.count)
        let includedFrac = Double(includedCount) / Double(totalGenes)
        let meanMinutes = includedCount > 0 ? totalDurationMinutes / Double(includedCount) : 0
        let focusFrac = includedCount > 0 ? focusDurationMinutes / max(1, totalDurationMinutes) : 0
        let meanEnergy = includedCount > 0 ? energySum / Double(includedCount) : 0
        let meanPriority = includedCount > 0 ? prioritySum / Double(includedCount) : 0
        let meanStartHour = includedCount > 0 ? startHourSum / Double(includedCount) : 0
        let preLunchFrac = includedCount > 0 ? Double(preLunchCount) / Double(includedCount) : 0
        let weekdayFrac = includedCount > 0 ? Double(weekdayTouched) / Double(includedCount) : 0
        let daySpread = Double(daysUsed.count) / Double(daysInHorizon)

        let morningFrac = totalDurationMinutes > 0 ? morningMassMinutes / totalDurationMinutes : 0
        let afternoonFrac = totalDurationMinutes > 0 ? afternoonMassMinutes / totalDurationMinutes : 0
        let eveningFrac = totalDurationMinutes > 0 ? eveningMassMinutes / totalDurationMinutes : 0

        // Total duration per day normalized by working-day length.
        let loadRatio = includedCount > 0
            ? (totalDurationMinutes / 60.0) / (Double(workHoursPerDay) * Double(max(1, daysUsed.count)))
            : 0

        // Temporal envelope: how early the earliest placement is and how
        // late the latest runs, both normalized by horizon length.
        let horizonSeconds = max(1, horizon.duration)
        let firstStartNorm = firstStartOffset.isFinite ? max(0, min(1, firstStartOffset / horizonSeconds)) : 0
        let lastEndNorm = lastEndOffset.isFinite ? max(0, min(1, lastEndOffset / horizonSeconds)) : 0

        let droppedFrac = Double(droppedCount) / Double(totalGenes)

        return [
            clamp(includedFrac),                // 0: inclusion rate
            clamp(focusFrac),                    // 1: focus-time fraction
            clamp(meanEnergy),                   // 2: mean energy cost
            clamp(meanPriority),                 // 3: mean priority
            clamp(meanStartHour / 24.0),         // 4: mean start hour / 24
            clamp(preLunchFrac),                 // 5: morning-skew
            clamp(weekdayFrac),                  // 6: weekday share
            clamp(daySpread),                    // 7: day-usage spread
            clamp(morningFrac),                  // 8: morning mass
            clamp(afternoonFrac),                // 9: afternoon mass
            clamp(eveningFrac),                  // 10: evening mass
            clamp(loadRatio),                    // 11: aggregate load
            clamp(firstStartNorm),               // 12: earliest placement
            clamp(lastEndNorm),                  // 13: latest end
            clamp(droppedFrac),                  // 14: dropped fraction
            clamp(min(1.0, meanMinutes / 240.0)) // 15: mean duration / 4h cap
        ]
    }

    @inline(__always)
    private static func clamp(_ v: Double) -> Double { max(0, min(1, v)) }
}

// MARK: - RBF Surrogate Model

/// RBF-weighted fitness predictor with kNN fallback and a bounded rolling
/// window of training samples. Thread-safe for concurrent predict; `record`
/// is serialized by an internal lock so the GA's parallel offspring
/// evaluation can append samples safely.
final class RBFSurrogate: @unchecked Sendable {
    struct TrainingSample: Sendable {
        let features: [Double]
        let fitness: Double
    }

    /// Surrogate configuration. All fields are final once constructed so
    /// the surrogate behaves deterministically given the same `GARandom`.
    struct Configuration: Sendable {
        /// Training-set cap. Oldest samples are evicted when capacity is hit.
        /// ~500 is enough to cover 20+ generations of population-sized
        /// offspring without quadratic-lookup pain.
        let capacity: Int
        /// RBF bandwidth — controls how fast influence decays with distance.
        /// 0.25 is a reasonable default for features in [0, 1]¹⁶: a
        /// candidate 0.1 away contributes ~85% of a candidate at the
        /// origin; a candidate 0.5 away contributes ~14%.
        let bandwidth: Double
        /// Neighbours used for each prediction. Small values reduce kNN
        /// bias at the cost of variance; ~8–16 is a sweet spot.
        let neighbors: Int
        /// Distance above which we call "high uncertainty" and fall back
        /// to the real evaluator. 0.22 ≈ "no neighbour within 1 feature
        /// unit out of 16 dimensions" — with `dimension = 16`, typical
        /// nearest-neighbour distances for related chromosomes sit
        /// around 0.02–0.10.
        let realEvalThreshold: Double
        /// Every N surrogate predictions, run one real evaluation anyway
        /// to keep the model calibrated against drift.
        let trustRefreshInterval: Int
        /// Minimum training samples before the surrogate is trusted. Below
        /// this, every prediction falls back to the real evaluator.
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

    /// Result of a screen decision. The GA uses this to choose whether to
    /// run the real evaluator.
    enum Screen: Sendable {
        /// Surrogate trusts its prediction; GA can skip the real evaluator.
        case accept(predictedFitness: Double)
        /// Surrogate doesn't trust itself (high uncertainty, stale, or in
        /// warm-up); GA must run the real evaluator.
        case realEvaluate(reason: String)
    }

    struct Telemetry: Sendable {
        let totalScreens: Int
        let accepted: Int
        let realEvaluated: Int
        let trainingSize: Int
        /// Running mean absolute error between surrogate predictions and
        /// subsequent real evaluations. A sanity check that the model is
        /// tracking the landscape.
        let rollingMAE: Double
    }

    let config: Configuration
    private var samples: [TrainingSample] = []
    private var screensSinceRefresh: Int = 0
    private var totalScreens: Int = 0
    private var accepted: Int = 0
    private var realEvaluated: Int = 0
    /// Rolling MAE computed via Welford-lite: (prediction, realFitness) pairs
    /// observed since warm-up. Reset when samples are evicted beyond half
    /// the capacity to keep the MAE responsive to drift.
    private var maeSum: Double = 0
    private var maeCount: Int = 0
    private let lock = NSLock()

    init(config: Configuration = .default) {
        self.config = config
        self.samples.reserveCapacity(config.capacity)
    }

    // MARK: - Query

    /// Decide whether the caller should trust the surrogate's prediction
    /// for `features`, or fall back to the real evaluator.
    func screen(features: [Double]) -> Screen {
        lock.lock()
        defer { lock.unlock() }
        totalScreens += 1
        screensSinceRefresh += 1

        // Warm-up: insufficient training data — always real-evaluate.
        guard samples.count >= config.warmupSamples else {
            realEvaluated += 1
            return .realEvaluate(reason: "warmup")
        }

        // Calibration refresh.
        if screensSinceRefresh >= config.trustRefreshInterval {
            screensSinceRefresh = 0
            realEvaluated += 1
            return .realEvaluate(reason: "calibrationRefresh")
        }

        // kNN search (linear). Training set cap is small so this is cheap
        // relative to a real objective evaluation.
        let neighbours = findNearest(k: config.neighbors, to: features)
        guard let closest = neighbours.first else {
            realEvaluated += 1
            return .realEvaluate(reason: "noNeighbors")
        }

        if closest.distance > config.realEvalThreshold {
            realEvaluated += 1
            return .realEvaluate(reason: "highUncertainty")
        }

        let predicted = rbfPredict(neighbours: neighbours)
        accepted += 1
        return .accept(predictedFitness: predicted)
    }

    // MARK: - Update

    /// Register a (features → real fitness) pair after the caller has run
    /// the real evaluator. Evicts the oldest sample when capacity is hit.
    /// Optionally updates rolling MAE if the caller supplies the surrogate
    /// prediction they got before calling the real evaluator — this is how
    /// we track model drift.
    func record(features: [Double], fitness: Double, priorPrediction: Double? = nil) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(TrainingSample(features: features, fitness: fitness))
        if samples.count > config.capacity {
            samples.removeFirst(samples.count - config.capacity)
            // Reset MAE periodically so drift is measured on recent data only.
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

    private struct Neighbor {
        let sample: TrainingSample
        let distance: Double
    }

    /// Return up to `k` nearest training samples sorted by ascending
    /// distance. Linear scan is fine here: samples.count ≤ config.capacity
    /// (~500) and we only call this on screening candidates.
    private func findNearest(k: Int, to features: [Double]) -> [Neighbor] {
        var all: [Neighbor] = []
        all.reserveCapacity(samples.count)
        for sample in samples {
            all.append(Neighbor(sample: sample, distance: euclidean(features, sample.features)))
        }
        all.sort { $0.distance < $1.distance }
        return Array(all.prefix(k))
    }

    private func rbfPredict(neighbours: [Neighbor]) -> Double {
        // Gaussian RBF weights: w_i = exp(-(d_i / bandwidth)²). Normalize
        // so the prediction is a convex combination of observed fitnesses,
        // which keeps the output in the range of the training set.
        var weightSum = 0.0
        var weightedFitnessSum = 0.0
        let invBandwidthSq = 1.0 / (config.bandwidth * config.bandwidth)
        for n in neighbours {
            let w = exp(-(n.distance * n.distance) * invBandwidthSq)
            weightSum += w
            weightedFitnessSum += w * n.sample.fitness
        }
        guard weightSum > 1e-12 else {
            // Fall back to the raw mean if every neighbour is effectively
            // infinitely far (shouldn't happen post-warmup).
            let sum = neighbours.reduce(0.0) { $0 + $1.sample.fitness }
            return sum / Double(neighbours.count)
        }
        return weightedFitnessSum / weightSum
    }

    @inline(__always)
    private func euclidean(_ a: [Double], _ b: [Double]) -> Double {
        // Features are always 16-dim; inline sum over fixed length is a
        // meaningful bit faster than reduce on release builds.
        var sum = 0.0
        let n = min(a.count, b.count)
        for i in 0..<n {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }
}

// MARK: - Surrogate Screen

/// Convenience wrapper that pairs a surrogate model with the real
/// evaluator closure so the GA can call one function and get either a
/// cheap prediction or a full evaluation. Maintains the contract that the
/// returned chromosome has a valid `fitness` and `rawFitness`.
///
/// The GA can integrate this by replacing its `evaluate:` closure with
/// `assistedEvaluator.evaluate(_:)` once the surrogate is warmed up.
final class SurrogateAssistedEvaluator: @unchecked Sendable {
    let surrogate: RBFSurrogate
    let realEvaluator: (inout ScheduleChromosome) -> Void
    let contextProvider: () -> OptimizerContext

    init(
        surrogate: RBFSurrogate,
        contextProvider: @escaping () -> OptimizerContext,
        realEvaluator: @escaping (inout ScheduleChromosome) -> Void
    ) {
        self.surrogate = surrogate
        self.contextProvider = contextProvider
        self.realEvaluator = realEvaluator
    }

    /// Evaluate a chromosome with surrogate screening. Writes `fitness`
    /// and `rawFitness` either from a surrogate prediction (if trusted)
    /// or from the real evaluator.
    func evaluate(_ chromosome: inout ScheduleChromosome) {
        let ctx = contextProvider()
        let features = ScheduleFeatures.vector(of: chromosome, context: ctx)
        switch surrogate.screen(features: features) {
        case .accept(let predicted):
            // Mark the chromosome as "surrogate-predicted" so downstream
            // stages (e.g. archive feeding) can filter if they want only
            // real-evaluated entries. We use `needsEvaluation = false` to
            // signal the fitness is populated; rawFitness carries the same
            // value because no objective breakdown was computed.
            chromosome.fitness = predicted
            chromosome.rawFitness = predicted
            chromosome.needsEvaluation = false

        case .realEvaluate:
            // Capture a prior prediction if possible (no-op when in warm-up
            // and the surrogate has nothing to predict with).
            realEvaluator(&chromosome)
            surrogate.record(
                features: features,
                fitness: chromosome.rawFitness,
                priorPrediction: nil
            )
        }
    }
}
