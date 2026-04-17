import Foundation

// MARK: - Mutation Operators

/// The four mutation strategies currently implemented in
/// `ScheduleChromosome.mutate`. Named explicitly so the bandit can address
/// them by identity rather than by "int 0..3", which would be error-prone as
/// the set grows.
enum MutationOperator: Int, CaseIterable, Sendable, Hashable {
    /// Small ±30-minute shift around the current start time. Fastest op;
    /// produces tight local neighbourhoods, good for fine-tuning.
    case shift = 0

    /// Relocate the gene to a randomly chosen day within the horizon.
    /// Explores globally; useful early in evolution and when the schedule
    /// is badly off from the global optimum.
    case moveDay = 1

    /// Snap the gene's start to the nearest half-hour. Cheap cleanup op;
    /// rarely produces big improvements but never wrecks a good layout.
    case snap = 2

    /// Guided: scan for the nearest free gap that fits the gene's duration
    /// and place there. Most expensive per invocation; typically the highest
    /// average reward once the schedule is near-feasible.
    case guided = 3
}

// MARK: - Bandit Context
//
// Three descriptors of the current population state, all in [0, 1]. The
// bandit uses them as features in a LinUCB model so operator choice varies
// with whatever regime the GA is in.

/// Vector of situational features the bandit conditions on. A 4th constant
/// "1" coefficient is appended internally as the intercept term — callers
/// construct a `BanditContext` with the three semantic features only.
struct BanditContext: Sendable {
    /// Population diversity in [0, 1]. Low = converged.
    let diversity: Double
    /// Stagnation ratio in [0, 1]. High = many stale generations since the
    /// last improvement.
    let stagnation: Double
    /// Objective imbalance in [0, 1]. Standard deviation across objective
    /// scores on the best individual, rescaled so 1 ≈ "one objective is
    /// dominating everything else" and 0 ≈ "all objectives equally-met".
    let imbalance: Double

    static let neutral = BanditContext(diversity: 0.5, stagnation: 0.0, imbalance: 0.0)

    /// Feature vector with intercept. Lives here so both select and record
    /// produce byte-identical `x` values for the same context.
    var featureVector: [Double] {
        // Clamp at construction in case a caller supplies out-of-range
        // inputs (defensive — fitness diversity can numerically exceed 1
        // in pathological populations).
        [
            1.0,
            max(0, min(1, diversity)),
            max(0, min(1, stagnation)),
            max(0, min(1, imbalance))
        ]
    }
}

// MARK: - Contextual Mutation Bandit (LinUCB)

/// LinUCB contextual bandit over mutation operators. Replaces the flat UCB1
/// that ignored population state — now the arm choice varies with whether
/// the GA is converging, diversifying, or stuck on one objective.
///
/// Model per arm `k`:
///   A_k = λ I + Σ x_t x_tᵀ
///   b_k = Σ r_t x_t
///   μ̂_k(x) = (A_k⁻¹ b_k) · x
///   σ̂_k(x) = α · sqrt(xᵀ A_k⁻¹ x)
///   score = μ̂_k(x) + σ̂_k(x)
///
/// The 4-dim feature vector is (1, diversity, stagnation, imbalance), so
/// every matrix is 4×4 and inversion is closed-form (Gauss–Jordan in the
/// loop, ~microseconds per `select`). Shared across islands via NSLock —
/// contention is negligible compared to fitness evaluation cost.
///
/// Thread safety: islands run in parallel and share one bandit; select /
/// record acquire the lock for O(d²) work (~16 float ops) before releasing.
final class MutationBandit: @unchecked Sendable {
    private struct Arm {
        /// Information matrix A = λI + Σ xxᵀ. Invertible as long as λ > 0.
        var A: [[Double]]
        /// Reward-weighted feature sum b = Σ r x.
        var b: [Double]
        /// Total pulls — informational, not used in the LinUCB update.
        var pulls: Int = 0
        /// Sum of raw (pre-squash) rewards — informational.
        var rewardSum: Double = 0

        init(dim: Int, lambda: Double) {
            A = (0..<dim).map { i in
                (0..<dim).map { j in i == j ? lambda : 0.0 }
            }
            b = [Double](repeating: 0, count: dim)
        }
    }

    private var arms: [MutationOperator: Arm] = [:]
    private var currentContext: BanditContext = .neutral
    private let lock = NSLock()

    /// UCB exploration multiplier. LinUCB's bound derives `α = 1 + sqrt(ln(2/δ)/2)`;
    /// with δ = 0.1 that's ≈ 1.96. We use a slightly smaller value because GA
    /// populations give every arm many pulls per generation, so we lean on
    /// exploitation sooner than a tabular bandit would.
    let explorationAlpha: Double

    /// Ridge regularization. Keeps A_k positive-definite when an arm has
    /// been pulled few times and every feature vector happens to be
    /// colinear (rare, but the inversion would blow up without λ).
    let regularizationLambda: Double

    /// Feature dimension (= `BanditContext.featureVector.count`).
    static let featureDim = 4

    init(explorationAlpha: Double = 1.5, regularizationLambda: Double = 1.0) {
        self.explorationAlpha = explorationAlpha
        self.regularizationLambda = regularizationLambda
        for op in MutationOperator.allCases {
            arms[op] = Arm(dim: Self.featureDim, lambda: regularizationLambda)
        }
    }

    // MARK: - Context update

    /// Called once per generation by the GA loop to refresh the context
    /// features. Every subsequent `select` / `record` until the next
    /// `updateContext` call uses this vector.
    func updateContext(_ context: BanditContext) {
        lock.lock()
        currentContext = context
        lock.unlock()
    }

    // MARK: - Select

    /// Pick the operator with the highest LinUCB score for the current
    /// context. Deterministic under a fixed RNG — ties are broken with
    /// the supplied `GARandom` so runs stay reproducible.
    func select(rng: GARandom) -> MutationOperator {
        lock.lock()
        defer { lock.unlock() }
        let x = currentContext.featureVector
        var bestOp = MutationOperator.shift
        var bestScore = -Double.infinity
        var ties: [MutationOperator] = []

        for op in MutationOperator.allCases {
            guard let arm = arms[op] else { continue }
            guard let aInv = Self.invert4x4(arm.A) else { continue }
            let theta = Self.matvec(aInv, arm.b)
            let mean = Self.dot(theta, x)
            let xAinvX = max(0, Self.quadForm(x, aInv))
            let bonus = explorationAlpha * xAinvX.squareRoot()
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

    /// Record an observed reward for the operator that was most recently
    /// selected. `reward` is the fitness delta (post - pre) — LinUCB
    /// tolerates negative rewards directly, no sigmoid squashing needed.
    /// We clip the magnitude so a single pathological mutation can't
    /// dominate the running estimate.
    func record(op: MutationOperator, reward: Double) {
        // Clip to [-0.5, +0.5] — typical per-generation fitness deltas
        // sit in [-0.1, +0.1]; larger values are almost always spikes
        // from a newly-feasible schedule and should not overwhelm the
        // running mean. Clipping also keeps θ well-scaled when operators
        // get lucky early.
        let clipped = max(-0.5, min(0.5, reward))
        lock.lock()
        defer { lock.unlock() }

        let x = currentContext.featureVector
        guard var arm = arms[op] else { return }
        // A += x xᵀ
        for i in 0..<Self.featureDim {
            for j in 0..<Self.featureDim {
                arm.A[i][j] += x[i] * x[j]
            }
        }
        // b += reward · x
        for i in 0..<Self.featureDim {
            arm.b[i] += clipped * x[i]
        }
        arm.pulls += 1
        arm.rewardSum += clipped
        arms[op] = arm
    }

    // MARK: - Telemetry

    struct ArmTelemetry: Sendable {
        let pulls: Int
        let meanReward: Double
        /// Estimated weight vector θ_k — useful for debugging which context
        /// features the arm is exploiting. First element is the intercept.
        let theta: [Double]
    }

    /// Snapshot for tests and logging. Computes θ_k = A_k⁻¹ b_k on read so
    /// callers see the freshest model state.
    var snapshot: [MutationOperator: ArmTelemetry] {
        lock.lock()
        defer { lock.unlock() }
        var out: [MutationOperator: ArmTelemetry] = [:]
        for (op, arm) in arms {
            let mean = arm.pulls > 0 ? arm.rewardSum / Double(arm.pulls) : 0
            let theta: [Double]
            if let aInv = Self.invert4x4(arm.A) {
                theta = Self.matvec(aInv, arm.b)
            } else {
                theta = [Double](repeating: 0, count: Self.featureDim)
            }
            out[op] = ArmTelemetry(pulls: arm.pulls, meanReward: mean, theta: theta)
        }
        return out
    }

    // MARK: - Federated learning hooks

    /// Export every arm's raw sufficient statistics. Used by
    /// `FederatedMutationBandit` to merge bandit state across islands.
    /// Returns a deep-copied snapshot so callers can mutate freely
    /// without affecting the live bandit.
    func rawArmsForFederation() -> [MutationOperator: ArmStatistics] {
        lock.lock()
        defer { lock.unlock() }
        var out: [MutationOperator: ArmStatistics] = [:]
        for (op, arm) in arms {
            let ACopy = arm.A.map { Array($0) }
            let bCopy = Array(arm.b)
            out[op] = ArmStatistics(A: ACopy, b: bCopy, pulls: arm.pulls, rewardSum: arm.rewardSum)
        }
        return out
    }

    /// Overwrite every arm's A/b/pulls/rewardSum with blended statistics
    /// produced by a federated merge. Missing operators are left
    /// untouched; dimensionality is validated per-arm and skipped on
    /// mismatch.
    func applyFederatedBlend(
        _ blended: [MutationOperator: (A: [[Double]], b: [Double], pulls: Int, rewardSum: Double)]
    ) {
        lock.lock()
        defer { lock.unlock() }
        for (op, incoming) in blended {
            guard var arm = arms[op] else { continue }
            guard incoming.A.count == Self.featureDim,
                  incoming.A.allSatisfy({ $0.count == Self.featureDim }),
                  incoming.b.count == Self.featureDim else {
                continue
            }
            arm.A = incoming.A.map { Array($0) }
            arm.b = Array(incoming.b)
            arm.pulls = incoming.pulls
            arm.rewardSum = incoming.rewardSum
            arms[op] = arm
        }
    }

    // MARK: - Linear algebra (inline 4×4)

    /// Closed-form 4×4 inverse via Gauss–Jordan. Returns `nil` when the
    /// matrix is singular (never happens in practice thanks to λI).
    private static func invert4x4(_ m: [[Double]]) -> [[Double]]? {
        precondition(m.count == 4 && m.allSatisfy { $0.count == 4 })
        // Build augmented 4×8 [M | I].
        var a = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 4)
        for i in 0..<4 {
            for j in 0..<4 { a[i][j] = m[i][j] }
            a[i][4 + i] = 1.0
        }
        for col in 0..<4 {
            // Partial pivot: find the row with the largest absolute value
            // in this column and swap into place. Guards against zero or
            // tiny pivots that would blow up the reduction.
            var pivot = col
            for r in (col + 1)..<4 where abs(a[r][col]) > abs(a[pivot][col]) {
                pivot = r
            }
            if abs(a[pivot][col]) < 1e-12 { return nil }
            if pivot != col { a.swapAt(col, pivot) }
            // Scale pivot row to 1.
            let div = a[col][col]
            for j in 0..<8 { a[col][j] /= div }
            // Eliminate other rows.
            for r in 0..<4 where r != col {
                let factor = a[r][col]
                if factor == 0 { continue }
                for j in 0..<8 { a[r][j] -= factor * a[col][j] }
            }
        }
        var inv = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        for i in 0..<4 {
            for j in 0..<4 { inv[i][j] = a[i][4 + j] }
        }
        return inv
    }

    private static func matvec(_ m: [[Double]], _ v: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: v.count)
        for i in 0..<v.count {
            var sum = 0.0
            for j in 0..<v.count { sum += m[i][j] * v[j] }
            out[i] = sum
        }
        return out
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }

    private static func quadForm(_ x: [Double], _ m: [[Double]]) -> Double {
        let mx = matvec(m, x)
        return dot(x, mx)
    }
}

// MARK: - Adaptive Mutation Chromosome

/// Refinement of `Chromosome` for genomes that cooperate with `MutationBandit`.
/// Letting the GA see this protocol means we can wire reward feedback
/// generically without leaking the bandit surface into chromosomes that
/// don't use it (e.g. `PomodoroSequenceChromosome`).
protocol AdaptiveMutationChromosome: Chromosome {
    /// The operator picked on the most recent `mutate` call, or nil on
    /// a freshly-constructed chromosome whose `mutate()` has not yet run.
    var lastMutationOperator: MutationOperator? { get set }
}
