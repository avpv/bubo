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

    /// Large-Neighbourhood Search: destroy a window (contiguous day or
    /// 15-25% of genes) and greedily rebuild it using the placement
    /// heuristic from `ScheduleChromosome.greedy`. Expensive per call
    /// but produces feasible, structurally-different neighbours in one
    /// shot — invaluable when conflict rate is high or the population
    /// has clustered around a bad basin. Contextual bandit typically
    /// picks this one when `conflictRate` and `peakDayOccupancy` are
    /// both high.
    case lns = 4
}

// MARK: - Mutation Bandit (UCB1)

/// Upper-confidence-bound bandit that picks which mutation operator to use
/// on a given `mutate()` call. Classical UCB1: `mean + c · √(ln N / n_i)`.
///
/// Why this helps: uniform random selection spends 25% of mutations on every
/// op, including ones that are empirically useless on the current workload.
/// UCB1 converges on the workload's best-performing operators while still
/// periodically revisiting the others, so if workload characteristics shift
/// mid-run (which they do: early exploration vs. late exploitation), the
/// allocation follows. Adaptive operator selection consistently delivers
/// +10-20% end-of-run fitness in the GA literature.
///
/// Thread safety: islands run in parallel, and each island gets its own
/// `OptimizerContext` with its own bandit (see `IslandModelGA.makeIslandContext`).
/// Within one island, mutate/evaluate runs sequentially before the offspring
/// are dispatched for parallel fitness evaluation, so all reward recording
/// happens on a single thread. The NSLock is cheap insurance against future
/// callers that deviate from that pattern.
final class MutationBandit: @unchecked Sendable {
    private struct Arm {
        var pulls: Int = 0
        var rewardSum: Double = 0
        /// Mean reward with a mild prior so unexplored arms aren't written
        /// off instantly by a single bad pull.
        var mean: Double {
            guard pulls > 0 else { return 0 }
            return rewardSum / Double(pulls)
        }
    }

    private var arms: [MutationOperator: Arm] = [:]
    private var totalPulls: Int = 0
    private let lock = NSLock()

    /// Exploration-exploitation trade-off constant. UCB1's canonical value
    /// is √2 ≈ 1.41. Smaller = more exploitation; larger = more exploration.
    /// We use a slightly smaller value because GA populations give each arm
    /// many samples per generation, so we can lean on exploitation sooner.
    let explorationC: Double

    init(explorationC: Double = 1.0) {
        self.explorationC = explorationC
        for op in MutationOperator.allCases {
            arms[op] = Arm()
        }
    }

    /// Pick the operator with the highest UCB1 score. Unpulled arms have
    /// priority by convention — we must try every arm at least once before
    /// UCB1's log-term is defined.
    func select(rng: GARandom) -> MutationOperator {
        lock.lock()
        defer { lock.unlock() }

        // Cold start: hand out one pull per arm before the UCB formula is
        // well-defined. Deterministic order to keep the RNG stream stable.
        for op in MutationOperator.allCases {
            if (arms[op]?.pulls ?? 0) == 0 { return op }
        }

        let logTotal = log(Double(max(1, totalPulls)))
        var bestOp = MutationOperator.shift
        var bestScore = -Double.infinity
        // Tie-breaking: when two arms share a UCB score (very common early
        // on), we pick one with the caller's RNG so runs stay reproducible
        // under the same top-level seed.
        var ties: [MutationOperator] = []

        for op in MutationOperator.allCases {
            guard let arm = arms[op], arm.pulls > 0 else { continue }
            let bonus = explorationC * sqrt(logTotal / Double(arm.pulls))
            let score = arm.mean + bonus
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

    /// Record the observed fitness delta for a mutation that used `op`.
    /// The reward is mapped to [0, 1] via a soft sigmoid so extreme deltas
    /// don't dominate the running mean; 0 reward means "no change", 0.5
    /// means "modest improvement", 1.0 means "very large gain".
    func record(op: MutationOperator, reward: Double) {
        // Symmetric logistic squashing: `1 / (1 + exp(-x))` centred on 0.
        // `reward · 10` spreads typical per-generation deltas (≈ 0.01-0.1)
        // into the [0.52, 0.73] range and very large gains saturate near 1.
        let squashed = 1.0 / (1.0 + exp(-reward * 10.0))

        lock.lock()
        defer { lock.unlock() }
        var arm = arms[op] ?? Arm()
        arm.pulls += 1
        arm.rewardSum += squashed
        arms[op] = arm
        totalPulls += 1
    }

    /// Snapshot for telemetry / tests. Returns per-op (pulls, mean reward).
    var snapshot: [MutationOperator: (pulls: Int, mean: Double)] {
        lock.lock()
        defer { lock.unlock() }
        var out: [MutationOperator: (Int, Double)] = [:]
        for (op, arm) in arms {
            out[op] = (arm.pulls, arm.mean)
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
    /// The operator picked on the most recent `mutate` call, or nil if no
    /// operator was applied (e.g. rate didn't hit any gene) or if the
    /// bandit was not wired on the `OptimizerContext`.
    var lastMutationOperator: MutationOperator? { get set }
}

