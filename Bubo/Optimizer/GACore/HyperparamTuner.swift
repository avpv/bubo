import Foundation

// MARK: - Workload-Keyed Hyperparameter Cache

/// Online store of well-performing `GAConfiguration` overrides keyed by
/// `WorkloadSignature`. At the start of each run, the tuner reads the
/// best hyperparameters observed for this workload and proposes them as
/// a mutation on the base config (only for parameters it owns). After
/// the run finishes with an observed best fitness, it records the
/// (signature, hyperparams, fitness) triple.
///
/// Think of this as a tiny Tree-structured Parzen Estimator (TPE) for
/// GA meta-tuning — we don't implement the full kernel-density story,
/// but we do keep "better than median" samples separate from "worse
/// than median" samples per signature, which is the foundational
/// element TPE expands on. Draws from the good-set with high
/// probability, from the bad-set with low probability; this matches
/// what TPE's `l(x)/g(x)` ratio does in spirit at 1% of the complexity.
///
/// Thread safety: single lock around the per-signature history.
final class HyperparamTuner: @unchecked Sendable {
    /// Tunable hyperparameters. Start small — every extra knob doubles
    /// the sample budget required to converge the tuner.
    struct TuningBounds: Sendable {
        var mutationRateMin: Double = 0.05
        var mutationRateMax: Double = 0.4
        var crossoverRateMin: Double = 0.6
        var crossoverRateMax: Double = 0.95
        var populationSizeMin: Int = 40
        var populationSizeMax: Int = 200
        var tournamentSizeMin: Int = 2
        var tournamentSizeMax: Int = 6
    }

    /// A single historical observation.
    struct Observation: Sendable {
        let mutationRate: Double
        let crossoverRate: Double
        let populationSize: Int
        let tournamentSize: Int
        let fitness: Double
    }

    private var history: [WorkloadSignature: [Observation]] = [:]
    private let lock = NSLock()
    let bounds: TuningBounds
    let perSignatureHistoryCap: Int

    init(bounds: TuningBounds = TuningBounds(), perSignatureHistoryCap: Int = 64) {
        self.bounds = bounds
        self.perSignatureHistoryCap = perSignatureHistoryCap
    }

    // MARK: - Proposal

    /// Propose an overridden config for this run. Strategy:
    ///   - Empty history → keep the base config unchanged.
    ///   - 1 sample      → perturb it slightly so the next run
    ///                     contributes meaningful contrast.
    ///   - ≥ 2 samples   → split by median fitness; with 80% prob sample
    ///                     (uniformly) from the good half, 20% from the
    ///                     bad half for exploration.
    func proposeConfig(base: GAConfiguration, signature: WorkloadSignature, rng: GARandom) -> GAConfiguration {
        lock.lock()
        let obs = history[signature] ?? []
        lock.unlock()

        if obs.isEmpty { return base }
        if obs.count == 1 {
            return perturb(base: base, seed: obs[0], rng: rng)
        }

        let sorted = obs.sorted { $0.fitness > $1.fitness }
        let median = sorted[sorted.count / 2].fitness
        let good = sorted.filter { $0.fitness > median }
        let bad = sorted.filter { $0.fitness <= median }

        let drawGood = rng.bool(probability: 0.8)
        let pool = drawGood && !good.isEmpty ? good : (!bad.isEmpty ? bad : sorted)
        let seed = pool[rng.int(in: 0..<pool.count)]
        return perturb(base: base, seed: seed, rng: rng)
    }

    /// Light Gaussian-ish perturbation around an observed sample. Keeps
    /// the proposal near-exploitative while still producing useful
    /// diversity each call.
    private func perturb(base: GAConfiguration, seed: Observation, rng: GARandom) -> GAConfiguration {
        var next = base
        let mRange = bounds.mutationRateMax - bounds.mutationRateMin
        let xRange = bounds.crossoverRateMax - bounds.crossoverRateMin
        let pJitter = (bounds.populationSizeMax - bounds.populationSizeMin) / 20
        let tJitter = max(1, (bounds.tournamentSizeMax - bounds.tournamentSizeMin) / 4)

        next.mutationRate = clamp(seed.mutationRate + rng.double(in: -0.1...0.1) * mRange,
                                  lo: bounds.mutationRateMin, hi: bounds.mutationRateMax)
        next.crossoverRate = clamp(seed.crossoverRate + rng.double(in: -0.1...0.1) * xRange,
                                   lo: bounds.crossoverRateMin, hi: bounds.crossoverRateMax)
        next.populationSize = clampInt(seed.populationSize + rng.int(in: -pJitter...pJitter),
                                       lo: bounds.populationSizeMin, hi: bounds.populationSizeMax)
        let t = clampInt(seed.tournamentSize + rng.int(in: -tJitter...tJitter),
                         lo: bounds.tournamentSizeMin, hi: bounds.tournamentSizeMax)
        next.selectionStrategy = .tournament(size: t)
        return next
    }

    // MARK: - Recording

    /// Append an observation. Evicts the weakest entries once the cap is
    /// reached so memory usage stays bounded per workload.
    func record(signature: WorkloadSignature, config: GAConfiguration, fitness: Double) {
        let tSize: Int
        switch config.selectionStrategy {
        case .tournament(let s): tSize = s
        default: tSize = bounds.tournamentSizeMin
        }

        let obs = Observation(
            mutationRate: config.mutationRate,
            crossoverRate: config.crossoverRate,
            populationSize: config.populationSize,
            tournamentSize: tSize,
            fitness: fitness
        )

        lock.lock()
        defer { lock.unlock() }

        var bucket = history[signature] ?? []
        bucket.append(obs)
        if bucket.count > perSignatureHistoryCap {
            bucket.sort { $0.fitness > $1.fitness }
            bucket = Array(bucket.prefix(perSignatureHistoryCap))
        }
        history[signature] = bucket
    }

    // MARK: - Introspection

    /// Snapshot of the history for tests / telemetry.
    func observations(for signature: WorkloadSignature) -> [Observation] {
        lock.lock(); defer { lock.unlock() }
        return history[signature] ?? []
    }

    /// Drop every observation; returns the tuner to a fresh state.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        history.removeAll()
    }

    // MARK: - Utilities

    private func clamp(_ v: Double, lo: Double, hi: Double) -> Double {
        min(hi, max(lo, v))
    }

    private func clampInt(_ v: Int, lo: Int, hi: Int) -> Int {
        min(hi, max(lo, v))
    }
}
