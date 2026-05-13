import Foundation

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
    var lastMutationOperator: MutationOperator? { get set }
}
