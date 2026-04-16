import Foundation

// MARK: - Surrogate Features

/// Feature vector for the fitness surrogate. Aggregates cheap gene-level
/// statistics that correlate with fitness but cost ~O(n) per chromosome
/// versus the O(n·objectives) cost of a real evaluation. Keep this small:
/// every extra feature is another weight in the ridge model the surrogate
/// has to fit, and with our tiny training set (a few thousand entries)
/// overfitting is the main risk.
struct SurrogateFeatures: Sendable {
    let focusFraction: Double
    let meetingDensity: Double
    let energyFit: Double
    let contextSwitches: Double
    let peakDayOccupancy: Double
    let weekdaySpread: Double
    let meanPriority: Double
    let inclusionRate: Double

    static let dimension = 9  // 8 features + bias

    var vector: [Double] {
        [1.0, focusFraction, meetingDensity, energyFit, contextSwitches,
         peakDayOccupancy, weekdaySpread, meanPriority, inclusionRate]
    }

    /// Extract from a chromosome. The first four features match
    /// `BehaviorDescriptor` components so the surrogate and novelty/QD
    /// archives stay aligned on shared vocabulary.
    init(chromosome: ScheduleChromosome, context: OptimizerContext) {
        let desc = BehaviorDescriptor(chromosome: chromosome, context: context)
        self.focusFraction = desc.focusFraction
        self.meetingDensity = desc.meetingDensity
        self.energyFit = desc.energyFit
        self.contextSwitches = desc.contextSwitches

        let active = chromosome.genes.filter { $0.isIncluded }
        let cal = context.calendar

        // Peak day occupancy.
        var occByDay: [Date: TimeInterval] = [:]
        for gene in active {
            let day = cal.startOfDay(for: gene.startTime)
            occByDay[day, default: 0] += gene.duration
        }
        let workingDaySeconds = Double(max(1, context.workingHours.upperBound - context.workingHours.lowerBound)) * 3600
        self.peakDayOccupancy = min(1.0, (occByDay.values.max() ?? 0) / workingDaySeconds)

        // Weekday spread: how many distinct days the schedule touches,
        // normalised against horizon length in days. Rewards balance.
        let uniqueDays = Set(active.map { cal.startOfDay(for: $0.startTime) }).count
        let horizonDays = max(1, Int(context.planningHorizon.duration / 86400))
        self.weekdaySpread = min(1.0, Double(uniqueDays) / Double(horizonDays))

        // Mean priority across included genes, normalised (priorities are
        // already in [0, 1]).
        if !active.isEmpty {
            self.meanPriority = active.reduce(0.0) { $0 + $1.priority } / Double(active.count)
        } else {
            self.meanPriority = 0
        }

        // Inclusion rate: 1 for non-droppable-only chromosomes, < 1 when
        // the GA chose to drop some droppable tasks.
        if chromosome.genes.isEmpty {
            self.inclusionRate = 0
        } else {
            self.inclusionRate = Double(active.count) / Double(chromosome.genes.count)
        }
    }
}

// MARK: - Fitness Surrogate (online ridge regression)

/// Cheap online surrogate over 8 schedule features. Fits a ridge linear
/// model y ≈ θ · x with closed-form updates on every real fitness
/// observation, so it learns continuously from whatever the evaluator
/// produces. The GA uses it in two modes:
///
///   1. **Pre-filter**: score offspring through the surrogate first;
///      send only the top-K by predicted fitness (plus a small random
///      budget) to the real evaluator. Saves evaluations when the
///      population is clearly separable by the surrogate.
///   2. **Preference ranking**: when two candidates have tied real
///      fitness, break the tie by surrogate to keep more "typical"
///      winners.
///
/// Why not a neural net? For populations in the 50-200 range and an
/// evaluator cost of milliseconds, a linear model trains in microseconds
/// per update and inferences in nanoseconds. A neural surrogate would
/// need hundreds of gradient steps per batch to pay back its setup cost
/// on the same workloads. The linear model pays back after ~30
/// observations on realistic schedules.
///
/// Thread safety: single NSLock; training happens on the main evaluation
/// thread (`FitnessEvaluator.evaluateAndAssign` is the usual caller), so
/// lock contention is effectively zero.
final class FitnessSurrogate: @unchecked Sendable {
    private let dimension: Int
    private let lambda: Double  // ridge regularisation
    private var A: [[Double]]   // D x D accumulator (λI + Σ x xᵀ)
    private var b: [Double]     // D accumulator Σ y·x
    private var thetaCache: [Double]?
    private var sampleCount: Int = 0
    private let lock = NSLock()

    /// Pre-filter knob: when true, `predictedTopK` returns the top K
    /// indices + an ε-random sample for exploration. The GA decides
    /// whether to honour that ranking via `GAConfiguration.surrogateK`
    /// (not yet plumbed; off by default until the model has accumulated
    /// enough samples). Check `warmedUp` before trusting predictions.
    var minSamplesForPrediction: Int = 30

    var warmedUp: Bool {
        lock.lock(); defer { lock.unlock() }
        return sampleCount >= minSamplesForPrediction
    }

    init(dimension: Int = SurrogateFeatures.dimension, lambda: Double = 1.0) {
        self.dimension = dimension
        self.lambda = lambda
        self.A = Array(repeating: Array(repeating: 0.0, count: dimension), count: dimension)
        for i in 0..<dimension { A[i][i] = lambda }
        self.b = Array(repeating: 0.0, count: dimension)
    }

    // MARK: - Training

    /// Incorporate a (features, observed fitness) pair. O(D²) per update,
    /// D=9 so this is effectively free next to the fitness evaluation
    /// that produced the label.
    func train(features: SurrogateFeatures, fitness: Double) {
        let x = features.vector
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<dimension {
            for j in 0..<dimension {
                A[i][j] += x[i] * x[j]
            }
            b[i] += fitness * x[i]
        }
        sampleCount += 1
        thetaCache = nil  // invalidate on every training sample
    }

    // MARK: - Prediction

    /// Predict fitness for a chromosome. Returns nil before the model is
    /// warmed up — callers should skip surrogate-based filtering until
    /// enough data has accumulated.
    func predict(_ chromosome: ScheduleChromosome, context: OptimizerContext) -> Double? {
        guard warmedUp else { return nil }
        let features = SurrogateFeatures(chromosome: chromosome, context: context)
        return predict(features: features)
    }

    /// Variant with pre-built features for tight loops (e.g. batch
    /// scoring of an offspring array).
    func predict(features: SurrogateFeatures) -> Double? {
        lock.lock()
        let theta = thetaCache ?? solve()
        if thetaCache == nil { thetaCache = theta }
        lock.unlock()
        guard let theta else { return nil }
        let x = features.vector
        var s = 0.0
        for i in 0..<dimension { s += theta[i] * x[i] }
        return s
    }

    /// Top-K pre-filter: score every `candidates` entry, return the
    /// indices with the highest predicted fitness plus `exploreCount`
    /// random extras (ε-greedy diversification against an overconfident
    /// surrogate). Order of returned indices is undefined; de-duplicated.
    func topKIndices(
        candidates: [ScheduleChromosome],
        context: OptimizerContext,
        k: Int,
        exploreCount: Int,
        rng: GARandom
    ) -> [Int]? {
        guard warmedUp, !candidates.isEmpty else { return nil }

        let predictions: [Double?] = candidates.map { chromo in
            predict(chromo, context: context)
        }

        let ranked = predictions.enumerated()
            .compactMap { (idx, pred) -> (Int, Double)? in
                guard let p = pred else { return nil }
                return (idx, p)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)

        var selected = Set<Int>(ranked.prefix(max(0, k)))
        if exploreCount > 0 {
            let pool = (0..<candidates.count).filter { !selected.contains($0) }
            for _ in 0..<min(exploreCount, pool.count) {
                let choice = pool[rng.int(in: 0..<pool.count)]
                selected.insert(choice)
            }
        }
        return Array(selected)
    }

    // MARK: - Linear solve

    /// Solve θ = A⁻¹ · b. Uses the same Gauss-Jordan routine as
    /// `ContextualBandit`, duplicated here to avoid exposing linear
    /// algebra helpers publicly — kept private so nothing outside these
    /// bandit/surrogate pairs accidentally relies on them.
    private func solve() -> [Double]? {
        let n = dimension
        var a = A
        var inv = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n { inv[i][i] = 1.0 }

        for col in 0..<n {
            var pivotRow = col
            var pivotVal = abs(a[col][col])
            for r in (col + 1)..<n where abs(a[r][col]) > pivotVal {
                pivotVal = abs(a[r][col])
                pivotRow = r
            }
            if pivotVal < 1e-12 { return nil }
            if pivotRow != col {
                a.swapAt(col, pivotRow)
                inv.swapAt(col, pivotRow)
            }
            let piv = a[col][col]
            for j in 0..<n {
                a[col][j] /= piv
                inv[col][j] /= piv
            }
            for r in 0..<n where r != col {
                let factor = a[r][col]
                if factor == 0 { continue }
                for j in 0..<n {
                    a[r][j] -= factor * a[col][j]
                    inv[r][j] -= factor * inv[col][j]
                }
            }
        }

        var theta = Array(repeating: 0.0, count: n)
        for i in 0..<n {
            var s = 0.0
            for j in 0..<n { s += inv[i][j] * b[j] }
            theta[i] = s
        }
        return theta
    }
}
