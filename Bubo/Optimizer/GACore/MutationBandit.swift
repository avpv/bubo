import Foundation

// MARK: - Mutation Operators

/// The mutation strategies currently implemented in
/// `ScheduleChromosome.mutate`. Named explicitly so the bandit can address
/// them by identity rather than by raw int, which would be error-prone as
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

    /// Large Neighborhood Search: destroy a coherent subset of the schedule
    /// (a whole day, or the top-K highest-priority genes) and greedily
    /// re-insert each into the best feasible slot. Unlike the other
    /// operators, LNS runs once per `mutate()` call instead of per gene —
    /// the destroy/repair pair is the atomic unit, and per-gene gating
    /// would fragment the reward signal. Expected to dominate late in the
    /// run when shift/snap/guided can't escape locally-good arrangements.
    case lnsDay = 4
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

    /// Read-only snapshot of the latest context. Exposed so operators that
    /// want to scale their neighbourhood with the same stagnation /
    /// diversity signal the bandit selects on can read it directly
    /// instead of threading the signal through `OptimizerContext`.
    var lastContext: BanditContext {
        lock.lock()
        defer { lock.unlock() }
        return currentContext
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

    /// Closed-form 4×4 inverse via cofactor expansion. Allocates one
    /// 16-entry buffer (vs. Gauss–Jordan's 32-entry augmented matrix
    /// plus per-row arithmetic) and produces results in ~80 fused
    /// multiply-adds. Returns `nil` when the determinant is below
    /// 1e-12 — never happens in practice thanks to ridge λI on every
    /// arm matrix.
    ///
    /// The expansion is the standard 4×4 cofactor formula written out
    /// linearly. It's verbose but every term is independent so the
    /// optimizer schedules them aggressively.
    private static func invert4x4(_ m: [[Double]]) -> [[Double]]? {
        precondition(m.count == 4 && m.allSatisfy { $0.count == 4 })

        // Unpack into named locals so the cofactor expressions read
        // cleanly. Letters follow row-major (a..p).
        let a = m[0][0], b = m[0][1], c = m[0][2], d = m[0][3]
        let e = m[1][0], f = m[1][1], g = m[1][2], h = m[1][3]
        let i = m[2][0], j = m[2][1], k = m[2][2], l = m[2][3]
        let n = m[3][0], o = m[3][1], p = m[3][2], q = m[3][3]

        // 2×2 minors of the bottom two rows; reused across the
        // first-row cofactor terms.
        let kp_lo = k * q - l * p
        let jp_lo = j * q - l * o
        let jo_kn = j * p - k * o
        let ip_lo = i * q - l * n
        let io_kn = i * p - k * n
        let in_jm = i * o - j * n

        // First-row cofactors (these also give the determinant).
        let A11 =  f * kp_lo - g * jp_lo + h * jo_kn
        let A12 = -(e * kp_lo - g * ip_lo + h * io_kn)
        let A13 =  e * jp_lo - f * ip_lo + h * in_jm
        let A14 = -(e * jo_kn - f * io_kn + g * in_jm)

        let det = a * A11 + b * A12 + c * A13 + d * A14
        if abs(det) < 1e-12 { return nil }
        let invDet = 1.0 / det

        // 2×2 minors involving rows 1, 2, 3 — needed for remaining
        // cofactors.
        let gp_ho = g * q - h * p
        let fp_ho = f * q - h * o
        let fo_gn = f * p - g * o
        let ep_ho = e * q - h * n
        let eo_gn = e * p - g * n
        let en_fm = e * o - f * n

        let A21 = -(b * kp_lo - c * jp_lo + d * jo_kn)
        let A22 =  a * kp_lo - c * ip_lo + d * io_kn
        let A23 = -(a * jp_lo - b * ip_lo + d * in_jm)
        let A24 =  a * jo_kn - b * io_kn + c * in_jm

        let A31 =  b * gp_ho - c * fp_ho + d * fo_gn
        let A32 = -(a * gp_ho - c * ep_ho + d * eo_gn)
        let A33 =  a * fp_ho - b * ep_ho + d * en_fm
        let A34 = -(a * fo_gn - b * eo_gn + c * en_fm)

        // 2×2 minors involving rows 1, 2 only — bottom row cofactors.
        let gl_hk = g * l - h * k
        let fl_hj = f * l - h * j
        let fk_gj = f * k - g * j
        let el_hi = e * l - h * i
        let ek_gi = e * k - g * i
        let ej_fi = e * j - f * i

        let A41 = -(b * gl_hk - c * fl_hj + d * fk_gj)
        let A42 =  a * gl_hk - c * el_hi + d * ek_gi
        let A43 = -(a * fl_hj - b * el_hi + d * ej_fi)
        let A44 =  a * fk_gj - b * ek_gi + c * ej_fi

        var inv = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        inv[0][0] = A11 * invDet; inv[0][1] = A21 * invDet
        inv[0][2] = A31 * invDet; inv[0][3] = A41 * invDet
        inv[1][0] = A12 * invDet; inv[1][1] = A22 * invDet
        inv[1][2] = A32 * invDet; inv[1][3] = A42 * invDet
        inv[2][0] = A13 * invDet; inv[2][1] = A23 * invDet
        inv[2][2] = A33 * invDet; inv[2][3] = A43 * invDet
        inv[3][0] = A14 * invDet; inv[3][1] = A24 * invDet
        inv[3][2] = A34 * invDet; inv[3][3] = A44 * invDet
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

// MARK: - LNS Destroy Strategy

/// Destroy heuristics available to `MutationOperator.lnsDay`. Each call to
/// the LNS operator picks one strategy via `LNSStrategyBandit`, rips out
/// the indicated subset, and lets the repair phase re-insert. The
/// taxonomy follows Shaw (1998) and Ropke & Pisinger (2006): one wide
/// destroy plus four narrower structure-aware ones.
enum LNSDestroyStrategy: Int, CaseIterable, Sendable, Hashable {
    /// Every gene sitting on one randomly-chosen day. Widest neighbourhood;
    /// good for intra-day gridlock.
    case day = 0

    /// Top-K genes by priority descending. Surgical; retouches the
    /// highest-value items without disturbing the rest.
    case topPriority = 1

    /// K uniformly-random genes. Pure exploration; pays off when the
    /// other heuristics lock into local patterns.
    case random = 2

    /// Seed + siblings sharing its context tag (or priority band if the
    /// seed has no tag). Shaw's "related removal".
    case relatedContext = 3

    /// Top-K genes by misfit score (overlaps + deadline miss + out-of-
    /// hours). Classic worst-removal; removes the most broken genes.
    case worstFit = 4
}

// MARK: - LNS Strategy Bandit (ALNS-style roulette)

/// Adaptive selector over `LNSDestroyStrategy`. Weights update via
/// exponential smoothing on observed fitness deltas, roulette selection
/// picks strategies proportional to their current weight.
///
/// This is the Ropke & Pisinger ALNS weight scheme rather than LinUCB —
/// the destroy-strategy feedback signal is coarser (one sample per LNS
/// call, no useful per-context features yet), so a simpler multiplicative
/// update converges faster than a contextual model would.
///
/// Weight update per call:
///   `w_s ← (1-λ)·w_s + λ·max(ε, reward)`
///
/// where `reward = clamp(rawFitnessDelta, -0.5, 0.5)`, `λ = 0.1`, and
/// `ε = 0.01` is a floor that keeps every strategy exploitable even
/// after a run of bad luck.
final class LNSStrategyBandit: @unchecked Sendable {
    private var weights: [LNSDestroyStrategy: Double]
    private var uses: [LNSDestroyStrategy: Int]
    private let lock = NSLock()

    /// Smoothing constant. Low values remember old rewards longer; we pick
    /// 0.1 so ~10 samples are needed to override a strategy's prior.
    let learningRate: Double

    /// Per-strategy weight floor so roulette never hits zero mass.
    let weightFloor: Double

    init(learningRate: Double = 0.1, weightFloor: Double = 0.01) {
        self.learningRate = learningRate
        self.weightFloor = weightFloor
        self.weights = Dictionary(uniqueKeysWithValues: LNSDestroyStrategy.allCases.map { ($0, 1.0) })
        self.uses = Dictionary(uniqueKeysWithValues: LNSDestroyStrategy.allCases.map { ($0, 0) })
    }

    /// Pick a strategy with probability proportional to its current
    /// weight. Fully deterministic under a fixed RNG — tie-breaking and
    /// roulette sampling both route through `rng`.
    func select(rng: GARandom) -> LNSDestroyStrategy {
        lock.lock()
        defer { lock.unlock() }
        // Iterate in a stable order for reproducibility.
        let ordered = LNSDestroyStrategy.allCases
        let total = ordered.reduce(0.0) { $0 + max(weightFloor, weights[$1] ?? weightFloor) }
        guard total > 0 else { return ordered[rng.int(in: 0..<ordered.count)] }
        let r = rng.double(in: 0..<total)
        var cumsum = 0.0
        for s in ordered {
            cumsum += max(weightFloor, weights[s] ?? weightFloor)
            if r < cumsum { return s }
        }
        return ordered.last!
    }

    /// Update the weight for the strategy used on the most recent LNS
    /// call. Reward is clipped before smoothing so one lucky (or
    /// pathological) call can't dominate the running mean. Non-positive
    /// rewards push the strategy toward `weightFloor` but don't drop it
    /// out of the roulette.
    func record(strategy: LNSDestroyStrategy, reward: Double) {
        let clipped = max(-0.5, min(0.5, reward))
        lock.lock()
        defer { lock.unlock() }
        uses[strategy, default: 0] += 1
        let current = weights[strategy] ?? 1.0
        // Map reward [-0.5, 0.5] → contribution [0, 1]; negative rewards
        // contribute near-zero (plus floor), positive push weight up.
        let contribution = max(weightFloor, clipped + 0.5)
        weights[strategy] = (1.0 - learningRate) * current + learningRate * contribution
    }

    // MARK: - Telemetry

    struct StrategyTelemetry: Sendable {
        let weight: Double
        let uses: Int
    }

    /// Snapshot for tests, logging, and island merges. Exposes current
    /// weights and pull counts without leaking the mutex-guarded state.
    var snapshot: [LNSDestroyStrategy: StrategyTelemetry] {
        lock.lock()
        defer { lock.unlock() }
        var out: [LNSDestroyStrategy: StrategyTelemetry] = [:]
        for s in LNSDestroyStrategy.allCases {
            out[s] = StrategyTelemetry(
                weight: weights[s] ?? 1.0,
                uses: uses[s] ?? 0
            )
        }
        return out
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
