import Foundation

// MARK: - Landscape Features

/// A compact snapshot of the current GA landscape, handed to
/// `ContextualBandit.select` so operator choice can depend on *where* the
/// search currently is rather than just on marginal arm means. All
/// components live in [0, 1] so the same feature vector shape works for
/// dot products with LinUCB's `theta` without manual rescaling.
struct LandscapeFeatures: Sendable {
    /// Progress through the maximum generation count: 0 at start, 1 at the
    /// final scheduled generation. Lets the bandit learn that `moveDay`
    /// is globally useful early but destructive late, and vice versa.
    let generationProgress: Double

    /// Genotypic diversity of the current population, normalised to [0, 1].
    /// Low diversity -> the population has converged, which favours
    /// diversifying operators like `lns` or `moveDay`.
    let genotypicDiversity: Double

    /// Fraction of the population whose chromosomes fail at least one
    /// hard constraint. High values favour `guided`/`lns` (which place
    /// into free gaps) over pure random time shifts.
    let conflictRate: Double

    /// Mean working-hour occupancy on the most loaded day in the horizon,
    /// scaled to [0, 1]. High occupancy means small shifts are unlikely
    /// to find room, so `moveDay` tends to outperform `shift`.
    let peakDayOccupancy: Double

    /// Average normalised distance from each individual to the current
    /// best. Close-to-best populations are in exploitation mode; far-apart
    /// populations are still exploring.
    let avgDistanceToBest: Double

    /// Flat feature vector [1.0, generationProgress, genotypicDiversity,
    /// conflictRate, peakDayOccupancy, avgDistanceToBest]. The leading
    /// 1.0 is the bias term that LinUCB fits unconditionally.
    var vector: [Double] {
        [1.0, generationProgress, genotypicDiversity, conflictRate, peakDayOccupancy, avgDistanceToBest]
    }

    static let dimension = 6
}

// MARK: - Contextual Bandit (LinUCB)

/// Linear Upper-Confidence-Bound contextual bandit — Li et al. 2010.
/// Each arm (mutation operator) maintains a linear model
///     E[reward | x] ≈ θ_a · x
/// plus a confidence interval that shrinks as we accumulate data. The arm
/// picked maximises `θ_a · x + α · sqrt(x · A_a⁻¹ · x)`, where the first
/// term is the expected reward under the current model and the second is
/// a feature-space-aware exploration bonus.
///
/// Closed-form update per arm:
///     A_a ← A_a + x xᵀ
///     b_a ← b_a + r · x
///     θ_a = A_a⁻¹ · b_a
///
/// This is the cheap, interpretable cousin of Neural Thompson Sampling:
/// it handles context natively, converges faster than UCB1 when landscape
/// features actually do predict which operator works, and falls back to
/// stateless UCB1 behaviour when they don't (every arm's θ stays near
/// zero, and the exploration term dominates).
///
/// Thread safety: single NSLock around the per-arm matrices because
/// islands may call `select` and `record` concurrently. A/b matrices are
/// tiny (6x6 doubles + 6-vector per arm) so lock contention is negligible
/// compared to the cost of a single mutation evaluation.
final class ContextualBandit: @unchecked Sendable {
    /// Per-arm linear model state. `A` is the regularised Gram matrix
    /// (initialised to λ·I so the first inversion is defined before any
    /// data arrives). `b` is the feature-weighted reward accumulator.
    private struct ArmState {
        var A: [[Double]]      // D x D
        var b: [Double]        // D
    }

    private var arms: [MutationOperator: ArmState] = [:]
    private let lock = NSLock()

    /// Most recently published landscape features. The GA loop calls
    /// `publish(features:)` before each generation so subsequent
    /// `select(...)` invocations pick an arm conditional on the current
    /// landscape state. Nil until the first publish; in that state
    /// `select(features:rng:)` must be called with an explicit feature
    /// vector (internal callers always have one).
    private var _currentFeatures: LandscapeFeatures?

    /// Publish the landscape features visible to subsequent `select`
    /// calls. Thread-safe: stored under the same lock that protects the
    /// per-arm matrices.
    func publish(features: LandscapeFeatures) {
        lock.lock(); defer { lock.unlock() }
        _currentFeatures = features
    }

    /// The most recently published features, or nil. Exposed for the
    /// mutation call path which does not directly see the GA loop.
    var currentFeatures: LandscapeFeatures? {
        lock.lock(); defer { lock.unlock() }
        return _currentFeatures
    }

    /// UCB exploration coefficient. Larger = more exploration; smaller =
    /// tighter exploitation. 1.0 is a standard safe default — LinUCB is
    /// less sensitive to α than UCB1 is to c because the square-root term
    /// already shrinks naturally with accumulated samples.
    let alpha: Double

    /// Ridge regression regulariser. Keeps A invertible when samples are
    /// few and prevents wild θ estimates on correlated features.
    let lambda: Double

    /// Feature dimensionality. Fixed at construction so every stored A/b
    /// has consistent shape. `LandscapeFeatures.dimension` is the canonical
    /// value for this codebase.
    let dimension: Int

    init(alpha: Double = 1.0, lambda: Double = 1.0, dimension: Int = LandscapeFeatures.dimension) {
        self.alpha = alpha
        self.lambda = lambda
        self.dimension = dimension
        for op in MutationOperator.allCases {
            arms[op] = ArmState(
                A: Self.identity(dimension: dimension, scale: lambda),
                b: Array(repeating: 0.0, count: dimension)
            )
        }
    }

    // MARK: - Selection

    /// Pick the operator maximising the LinUCB score given `features`.
    /// Ties are broken via the caller's `GARandom` for reproducibility.
    func select(features: LandscapeFeatures, rng: GARandom) -> MutationOperator {
        let x = features.vector
        precondition(x.count == dimension, "Feature vector size mismatch")

        lock.lock()
        defer { lock.unlock() }

        var bestOp = MutationOperator.shift
        var bestScore = -Double.infinity
        var ties: [MutationOperator] = []

        for op in MutationOperator.allCases {
            guard let arm = arms[op] else { continue }
            guard let aInv = Self.invert(arm.A) else { continue }
            let theta = Self.matVec(aInv, arm.b)
            let mean = Self.dot(theta, x)
            let variance = Self.dot(x, Self.matVec(aInv, x))
            let bonus = alpha * max(0, variance).squareRoot()
            let score = mean + bonus

            if score > bestScore + 1e-12 {
                bestScore = score
                bestOp = op
                ties = [op]
            } else if abs(score - bestScore) < 1e-12 {
                ties.append(op)
            }
        }

        if ties.count > 1 {
            return ties[rng.int(in: 0..<ties.count)]
        }
        return bestOp
    }

    // MARK: - Record

    /// Close the feedback loop with the observed (squashed) reward for an
    /// operator called with `features`.
    func record(op: MutationOperator, features: LandscapeFeatures, reward: Double) {
        // Symmetric logistic squash, same family as `MutationBandit.record`
        // so rewards coming from both bandit flavours live on comparable
        // scales if a consumer ever averages across them.
        let squashed = 1.0 / (1.0 + exp(-reward * 10.0))
        let x = features.vector
        precondition(x.count == dimension, "Feature vector size mismatch")

        lock.lock()
        defer { lock.unlock() }
        guard var arm = arms[op] else { return }
        // A ← A + x·xᵀ
        for i in 0..<dimension {
            for j in 0..<dimension {
                arm.A[i][j] += x[i] * x[j]
            }
        }
        // b ← b + r · x
        for i in 0..<dimension {
            arm.b[i] += squashed * x[i]
        }
        arms[op] = arm
    }

    // MARK: - Snapshot

    /// For tests and telemetry: returns a copy of the per-arm ridge θ.
    /// Callers can inspect which features each arm has learned to value.
    func thetaSnapshot() -> [MutationOperator: [Double]] {
        lock.lock(); defer { lock.unlock() }
        var out: [MutationOperator: [Double]] = [:]
        for (op, arm) in arms {
            guard let aInv = Self.invert(arm.A) else { continue }
            out[op] = Self.matVec(aInv, arm.b)
        }
        return out
    }

    // MARK: - Linear algebra helpers (6x6 is tiny; no BLAS needed)

    private static func identity(dimension: Int, scale: Double) -> [[Double]] {
        var m = Array(repeating: Array(repeating: 0.0, count: dimension), count: dimension)
        for i in 0..<dimension { m[i][i] = scale }
        return m
    }

    private static func matVec(_ m: [[Double]], _ v: [Double]) -> [Double] {
        var out = Array(repeating: 0.0, count: v.count)
        for i in 0..<v.count {
            var s = 0.0
            for j in 0..<v.count { s += m[i][j] * v[j] }
            out[i] = s
        }
        return out
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }

    /// Gauss-Jordan inversion on a (D x D) dense matrix. D = 6 in practice,
    /// so the O(D³) cost is ~220 flops per select — negligible next to a
    /// fitness evaluation. Returns nil on singular input; caller falls back
    /// to skipping that arm (legacy UCB1 behaviour).
    private static func invert(_ m: [[Double]]) -> [[Double]]? {
        let n = m.count
        var a = m
        var inv = identity(dimension: n, scale: 1.0)

        for col in 0..<n {
            // Partial pivot: find the row below with the largest absolute
            // value in this column and swap up. Stabilises the inversion
            // against near-zero diagonal entries that would explode.
            var pivotRow = col
            var pivotVal = abs(a[col][col])
            for r in (col + 1)..<n {
                if abs(a[r][col]) > pivotVal {
                    pivotVal = abs(a[r][col])
                    pivotRow = r
                }
            }
            if pivotVal < 1e-12 { return nil }
            if pivotRow != col {
                a.swapAt(col, pivotRow)
                inv.swapAt(col, pivotRow)
            }

            // Scale pivot row to 1.
            let piv = a[col][col]
            for j in 0..<n {
                a[col][j] /= piv
                inv[col][j] /= piv
            }

            // Eliminate the current column from every other row.
            for r in 0..<n where r != col {
                let factor = a[r][col]
                if factor == 0 { continue }
                for j in 0..<n {
                    a[r][j] -= factor * a[col][j]
                    inv[r][j] -= factor * inv[col][j]
                }
            }
        }
        return inv
    }
}

// MARK: - Feature Extraction

extension LandscapeFeatures {
    /// Build features from a live GA population + context. Called once per
    /// `mutate()` call, so it has to be O(popSize) at worst — any heavier
    /// computation would dominate the mutation cost.
    static func extract(
        population: [ScheduleChromosome],
        best: ScheduleChromosome?,
        context: OptimizerContext,
        generation: Int,
        maxGenerations: Int,
        constraintEngine: ConstraintEngine
    ) -> LandscapeFeatures {
        let progress = maxGenerations > 0 ? min(1.0, Double(generation) / Double(maxGenerations)) : 0
        guard !population.isEmpty else {
            return LandscapeFeatures(
                generationProgress: progress,
                genotypicDiversity: 0,
                conflictRate: 0,
                peakDayOccupancy: 0,
                avgDistanceToBest: 0
            )
        }

        // Genotypic diversity on a capped sample — same pattern as the
        // main GA's diversity measurement, so features and the existing
        // diversity signal stay on the same scale.
        let sampleSize = min(20, population.count)
        let sample = Array(population.prefix(sampleSize))
        var totalDist = 0.0
        var pairs = 0
        for i in 0..<sample.count {
            for j in (i + 1)..<sample.count {
                totalDist += sample[i].distance(to: sample[j])
                pairs += 1
            }
        }
        let diversity = pairs > 0 ? totalDist / Double(pairs) : 0

        // Conflict rate: fraction of individuals that fail a hard check.
        var conflicts = 0
        for ind in population {
            if !constraintEngine.isValid(ind, context: context) { conflicts += 1 }
        }
        let conflictRate = Double(conflicts) / Double(population.count)

        // Peak day occupancy: find the most loaded day across the best
        // individual; fall back to the first one if no best is known.
        let cal = context.calendar
        let reference = best ?? population[0]
        var occByDay: [Date: TimeInterval] = [:]
        for gene in reference.genes where gene.isIncluded {
            let day = cal.startOfDay(for: gene.startTime)
            occByDay[day, default: 0] += gene.duration
        }
        let workingDaySeconds = Double(max(1, context.workingHours.upperBound - context.workingHours.lowerBound)) * 3600
        let peakOcc = (occByDay.values.max() ?? 0) / workingDaySeconds
        let peakClamped = min(1.0, max(0, peakOcc))

        // Avg distance to best.
        let avgDist: Double
        if let ref = best {
            var sum = 0.0
            for ind in sample {
                sum += ind.distance(to: ref)
            }
            avgDist = sample.isEmpty ? 0 : sum / Double(sample.count)
        } else {
            avgDist = 0
        }

        return LandscapeFeatures(
            generationProgress: progress,
            genotypicDiversity: min(1.0, diversity),
            conflictRate: conflictRate,
            peakDayOccupancy: peakClamped,
            avgDistanceToBest: min(1.0, avgDist)
        )
    }
}
