import Foundation

// MARK: - Mutation Operators

/// The mutation strategies currently implemented in
/// `ScheduleChromosome.mutate`. Named explicitly so the bandit can address
/// them by identity rather than by raw int, which would be error-prone as
/// the set grows.
public enum MutationOperator: Int, CaseIterable, Sendable, Hashable {
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

/// Vector of situational features the bandit conditions on. A constant
/// "1" coefficient is appended internally as the intercept term — callers
/// construct a `BanditContext` with the semantic features only.
///
/// The graph-derived features (`precedenceViolationRate`, `conflictDensity`,
/// `maxChainDepth`) were added alongside graph preprocessing so the bandit can pick an
/// operator conditioned on how "graph-constrained" the current landscape
/// is. All three default to 0 so existing callers keep the original 4-dim
/// behaviour without code changes; the actual feature dimension is 6 plus
/// the intercept for the LinUCB model.
public struct BanditContext: Sendable {
    /// Population diversity in [0, 1]. Low = converged.
    public let diversity: Double
    /// Stagnation ratio in [0, 1]. High = many stale generations since the
    /// last improvement.
    public let stagnation: Double
    /// Objective imbalance in [0, 1]. Standard deviation across objective
    /// scores on the best individual, rescaled so 1 ≈ "one objective is
    /// dominating everything else" and 0 ≈ "all objectives equally-met".
    public let imbalance: Double
    /// Fraction of `dependsOn` pairs currently violated on the best
    /// individual in [0, 1]. High values should bias the bandit toward
    /// the guided (gap-finding) operator so the GA spends more
    /// evaluations on fixing precedence rather than exploring.
    public let precedenceViolationRate: Double
    /// Density of the conflict graph in [0, 1]. Dense landscapes reward
    /// tiny shifts (low neighbourhood rate) while sparse ones tolerate
    /// full day-moves — this feature lets LinUCB learn that mapping.
    public let conflictDensity: Double
    /// Normalised maximum precedence chain depth in [0, 1]. Proxy for
    /// "how far apart can dependents legally move?" — long chains make
    /// global moves disruptive, so the bandit should prefer local ops.
    public let maxChainDepth: Double

    public static let neutral = BanditContext(
        diversity: 0.5, stagnation: 0.0, imbalance: 0.0,
        precedenceViolationRate: 0, conflictDensity: 0, maxChainDepth: 0
    )

    public init(
        diversity: Double,
        stagnation: Double,
        imbalance: Double,
        precedenceViolationRate: Double = 0,
        conflictDensity: Double = 0,
        maxChainDepth: Double = 0
    ) {
        self.diversity = diversity
        self.stagnation = stagnation
        self.imbalance = imbalance
        self.precedenceViolationRate = precedenceViolationRate
        self.conflictDensity = conflictDensity
        self.maxChainDepth = maxChainDepth
    }

    /// Feature vector with intercept. Lives here so both select and record
    /// produce byte-identical `x` values for the same context.
    public var featureVector: [Double] {
        [
            1.0,
            max(0, min(1, diversity)),
            max(0, min(1, stagnation)),
            max(0, min(1, imbalance)),
            max(0, min(1, precedenceViolationRate)),
            max(0, min(1, conflictDensity)),
            max(0, min(1, maxChainDepth))
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
public final class MutationBandit: @unchecked Sendable {
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
    public let explorationAlpha: Double

    /// Ridge regularization. Keeps A_k positive-definite when an arm has
    /// been pulled few times and every feature vector happens to be
    /// colinear (rare, but the inversion would blow up without λ).
    public let regularizationLambda: Double

    /// Feature dimension (= `BanditContext.featureVector.count`).
    /// Bumped from 4 to 7 when the graph-derived features were added:
    /// the extra columns are `precedenceViolationRate`, `conflictDensity`,
    /// and `maxChainDepth`. LinUCB's closed-form update scales fine at
    /// this size because `invertNxN` below is Gauss–Jordan on a 7×7 — a
    /// few hundred flops per `select`, comparable to the old handrolled
    /// 4×4 cofactor expansion.
    public static let featureDim = 7

    public init(explorationAlpha: Double = 1.5, regularizationLambda: Double = 1.0) {
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
    public func updateContext(_ context: BanditContext) {
        lock.lock()
        currentContext = context
        lock.unlock()
    }

    /// Read-only snapshot of the latest context. Exposed so operators that
    /// want to scale their neighbourhood with the same stagnation /
    /// diversity signal the bandit selects on can read it directly
    /// instead of threading the signal through `OptimizerContext`.
    public var lastContext: BanditContext {
        lock.lock()
        defer { lock.unlock() }
        return currentContext
    }

    // MARK: - Select

    /// Pick the operator with the highest LinUCB score for the current
    /// context. Deterministic under a fixed RNG — ties are broken with
    /// the supplied `GARandom` so runs stay reproducible.
    public func select(rng: GARandom) -> MutationOperator {
        lock.lock()
        defer { lock.unlock() }
        let x = currentContext.featureVector
        var bestOp = MutationOperator.shift
        var bestScore = -Double.infinity
        var ties: [MutationOperator] = []

        // When the run is clearly stuck (stagnation ≥ 0.6), bias the
        // exploration bonus of the `guided` (gap-finding) operator
        // upward — its per-call cost is high, so LinUCB often avoids
        // it early, but it's the only operator that actively scans for
        // feasible free windows. Empirically, most of the late-run
        // improvements on plan-week workloads come from guided breaks
        // through crowded days, so we nudge the bandit toward trying
        // it more when nothing else is working. Same effect as giving
        // the arm a small late-run prior without perturbing its A/b.
        let stagnation = currentContext.stagnation
        let guidedBoost = stagnation >= 0.6 ? 1.0 + 0.5 * (stagnation - 0.6) / 0.4 : 1.0

        for op in MutationOperator.allCases {
            guard let arm = arms[op] else { continue }
            guard let aInv = Self.invertNxN(arm.A) else { continue }
            let theta = Self.matvec(aInv, arm.b)
            let mean = Self.dot(theta, x)
            let xAinvX = max(0, Self.quadForm(x, aInv))
            var bonus = explorationAlpha * xAinvX.squareRoot()
            if op == .guided { bonus *= guidedBoost }
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
    public func record(op: MutationOperator, reward: Double) {
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

    public struct ArmTelemetry: Sendable {

        public init(
            pulls: Int,
            meanReward: Double,
            theta: [Double]
        ) {
            self.pulls = pulls
            self.meanReward = meanReward
            self.theta = theta
        }

        public let pulls: Int
        public let meanReward: Double
        /// Estimated weight vector θ_k — useful for debugging which context
        /// features the arm is exploiting. First element is the intercept.
        public let theta: [Double]
    }

    /// Snapshot for tests and logging. Computes θ_k = A_k⁻¹ b_k on read so
    /// callers see the freshest model state.
    public var snapshot: [MutationOperator: ArmTelemetry] {
        lock.lock()
        defer { lock.unlock() }
        var out: [MutationOperator: ArmTelemetry] = [:]
        for (op, arm) in arms {
            let mean = arm.pulls > 0 ? arm.rewardSum / Double(arm.pulls) : 0
            let theta: [Double]
            if let aInv = Self.invertNxN(arm.A) {
                theta = Self.matvec(aInv, arm.b)
            } else {
                theta = [Double](repeating: 0, count: Self.featureDim)
            }
            out[op] = ArmTelemetry(pulls: arm.pulls, meanReward: mean, theta: theta)
        }
        return out
    }

    // MARK: - Linear algebra (generic N×N)

    /// Gauss–Jordan inverse of an N×N matrix with partial pivoting.
    /// Returns `nil` on (near-)singular input — ridge regularisation
    /// on every arm matrix means this path is cold in practice.
    ///
    /// Replaces the old handrolled 4×4 cofactor expansion because the
    /// LinUCB feature vector grew past 4 when graph features were
    /// added. At N = 7 the cost is ~350 multiplications per call,
    /// still in the microsecond range so bandit `select` keeps its
    /// latency profile.
    private static func invertNxN(_ m: [[Double]]) -> [[Double]]? {
        let n = m.count
        precondition(n > 0 && m.allSatisfy { $0.count == n })

        // Augmented matrix [A | I]. Flat-stored row major so the inner
        // loops don't chase nested array indirections.
        var a = [Double](repeating: 0, count: n * n * 2)
        let stride = 2 * n
        for i in 0..<n {
            for j in 0..<n {
                a[i * stride + j] = m[i][j]
            }
            a[i * stride + n + i] = 1
        }

        // Forward elimination with partial pivoting.
        for i in 0..<n {
            // Pivot: pick the row with largest |a[row][i]|.
            var pivotRow = i
            var pivotMag = abs(a[i * stride + i])
            for r in (i + 1)..<n {
                let mag = abs(a[r * stride + i])
                if mag > pivotMag {
                    pivotMag = mag
                    pivotRow = r
                }
            }
            if pivotMag < 1e-12 { return nil }

            if pivotRow != i {
                // Swap rows i and pivotRow in both halves.
                for j in 0..<stride {
                    let tmp = a[i * stride + j]
                    a[i * stride + j] = a[pivotRow * stride + j]
                    a[pivotRow * stride + j] = tmp
                }
            }

            // Normalise pivot row.
            let pivot = a[i * stride + i]
            let invPivot = 1.0 / pivot
            for j in 0..<stride {
                a[i * stride + j] *= invPivot
            }

            // Eliminate column i from all other rows.
            for r in 0..<n where r != i {
                let factor = a[r * stride + i]
                guard factor != 0 else { continue }
                for j in 0..<stride {
                    a[r * stride + j] -= factor * a[i * stride + j]
                }
            }
        }

        // Extract right half as the inverse.
        var inv = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n {
                inv[i][j] = a[i * stride + n + j]
            }
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

// MARK: - LNS Destroy Strategy

/// Destroy heuristics available to `MutationOperator.lnsDay`. Each call to
/// the LNS operator picks one strategy via `LNSStrategyBandit`, rips out
/// the indicated subset, and lets the repair phase re-insert. The
/// taxonomy follows Shaw (1998) and Ropke & Pisinger (2006): one wide
/// destroy plus four narrower structure-aware ones.
public enum LNSDestroyStrategy: Int, CaseIterable, Sendable, Hashable {
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
public final class LNSStrategyBandit: @unchecked Sendable {
    private var weights: [LNSDestroyStrategy: Double]
    private var uses: [LNSDestroyStrategy: Int]
    private let lock = NSLock()

    /// Smoothing constant. Low values remember old rewards longer; we pick
    /// 0.1 so ~10 samples are needed to override a strategy's prior.
    public let learningRate: Double

    /// Per-strategy weight floor so roulette never hits zero mass.
    public let weightFloor: Double

    public init(learningRate: Double = 0.1, weightFloor: Double = 0.01) {
        self.learningRate = learningRate
        self.weightFloor = weightFloor
        self.weights = Dictionary(uniqueKeysWithValues: LNSDestroyStrategy.allCases.map { ($0, 1.0) })
        self.uses = Dictionary(uniqueKeysWithValues: LNSDestroyStrategy.allCases.map { ($0, 0) })
    }

    /// Pick a strategy with probability proportional to its current
    /// weight. Fully deterministic under a fixed RNG — tie-breaking and
    /// roulette sampling both route through `rng`.
    public func select(rng: GARandom) -> LNSDestroyStrategy {
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
    public func record(strategy: LNSDestroyStrategy, reward: Double) {
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

    public struct StrategyTelemetry: Sendable {

        public init(
            weight: Double,
            uses: Int
        ) {
            self.weight = weight
            self.uses = uses
        }

        public let weight: Double
        public let uses: Int
    }

    /// Snapshot for tests, logging, and island merges. Exposes current
    /// weights and pull counts without leaking the mutex-guarded state.
    public var snapshot: [LNSDestroyStrategy: StrategyTelemetry] {
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

// MARK: - LNS Repair Strategy (full ALNS)

/// The second half of the adaptive large neighborhood search loop:
/// which repair heuristic re-inserts the destroyed genes.
///
/// Destroy strategies (`LNSDestroyStrategy`) pick *what* to rip out;
/// repair strategies pick *how* to put it back. Classical ALNS
/// (Ropke & Pisinger) runs independent bandits over both sides so the
/// combined policy converges on the pair that works best for the
/// current landscape — e.g. `topPriority × regret` on a tight week,
/// `day × cpSAT` when large-scale restructure pays off.
public enum LNSRepairStrategy: Int, CaseIterable, Sendable, Hashable {
    /// Internal branch-and-bound CP with forward checking + no-good
    /// clause learning. Strongest repair for small-to-medium windows;
    /// default path before ALNS.
    case branchAndBound = 0

    /// Regret-based insertion: places each destroyed gene into its
    /// best slot weighted by the gap to the *second*-best, so tightly
    /// bound genes get placed first. Fast and robust.
    case regret = 1

    /// External CP-SAT adapter (`CPSATRepairer`). Stronger than the
    /// in-house B&B on large windows but has a higher per-call cost;
    /// the old code gated it behind `cpSATWindowThreshold`, the
    /// bandit now learns that trade-off from experience.
    case cpSAT = 2
}

// MARK: - LNS Repair Bandit

/// Mirror of `LNSStrategyBandit` for repair heuristics. Same
/// exponential-smoothing roulette scheme so destroy + repair
/// bandits compose predictably: each LNS call selects *both*
/// ends of the pair via independent draws, then rewards each
/// separately with the same fitness delta. After enough
/// samples the weight-product reflects the true pair quality
/// without us having to explicitly enumerate `destroy × repair`
/// combinations (which would be 5 × 3 = 15 pairs — too many
/// for fast convergence on a short-budget GA run).
public final class LNSRepairBandit: @unchecked Sendable {
    private var weights: [LNSRepairStrategy: Double]
    private var uses: [LNSRepairStrategy: Int]
    private let lock = NSLock()

    public let learningRate: Double
    public let weightFloor: Double

    public init(learningRate: Double = 0.1, weightFloor: Double = 0.01) {
        self.learningRate = learningRate
        self.weightFloor = weightFloor
        self.weights = Dictionary(uniqueKeysWithValues: LNSRepairStrategy.allCases.map { ($0, 1.0) })
        self.uses = Dictionary(uniqueKeysWithValues: LNSRepairStrategy.allCases.map { ($0, 0) })
    }

    /// Pick a repair strategy proportional to its current weight.
    /// Deterministic under a fixed RNG — same tie-break semantics as
    /// `LNSStrategyBandit.select`.
    ///
    /// When `cpSATAvailable == false` the `.cpSAT` arm is excluded
    /// from the draw: the external solver isn't wired into this
    /// context, so putting probability mass on it would waste a
    /// selection. The bandit still learns on the other two arms.
    public func select(rng: GARandom, cpSATAvailable: Bool) -> LNSRepairStrategy {
        lock.lock()
        defer { lock.unlock() }
        let ordered = LNSRepairStrategy.allCases.filter { strategy in
            cpSATAvailable || strategy != .cpSAT
        }
        guard !ordered.isEmpty else { return .branchAndBound }
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

    /// Fitness-delta reward update, same curve as the destroy bandit:
    /// clip → shift → exponential smoothing. Negative rewards push
    /// toward the floor but don't evict the strategy.
    public func record(strategy: LNSRepairStrategy, reward: Double) {
        let clipped = max(-0.5, min(0.5, reward))
        lock.lock()
        defer { lock.unlock() }
        let current = weights[strategy] ?? 1.0
        let contribution = max(weightFloor, clipped + 0.5)
        weights[strategy] = (1.0 - learningRate) * current + learningRate * contribution
        uses[strategy, default: 0] += 1
    }

    public var snapshot: [LNSRepairStrategy: StrategyTelemetry] {
        lock.lock()
        defer { lock.unlock() }
        var out: [LNSRepairStrategy: StrategyTelemetry] = [:]
        for s in LNSRepairStrategy.allCases {
            out[s] = StrategyTelemetry(
                weight: weights[s] ?? 1.0,
                uses: uses[s] ?? 0
            )
        }
        return out
    }

    public struct StrategyTelemetry: Sendable {

        public init(
            weight: Double,
            uses: Int
        ) {
            self.weight = weight
            self.uses = uses
        }

        public let weight: Double
        public let uses: Int
    }
}

// MARK: - Adaptive Mutation Chromosome

/// Refinement of `Chromosome` for genomes that cooperate with `MutationBandit`.
/// Letting the GA see this protocol means we can wire reward feedback
/// generically without leaking the bandit surface into chromosomes that
/// don't use it (e.g. `PomodoroSequenceChromosome`).
public protocol AdaptiveMutationChromosome: Chromosome {
    /// The operator picked on the most recent `mutate` call, or nil on
    /// a freshly-constructed chromosome whose `mutate()` has not yet run.
    public var lastMutationOperator: MutationOperator? { get set }
}
