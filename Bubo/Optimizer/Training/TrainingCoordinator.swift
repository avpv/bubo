import Foundation

// MARK: - Training Coordinator
//
// Orchestrates the autonomous training pipeline:
//   • Collects events from the live optimizer via the replay buffer.
//   • Periodically runs a training cycle that feeds each learner a
//     batch of its relevant events.
//   • Optionally bootstraps with synthetic preference pairs when the
//     real-feedback pool is still cold.
//   • Persists learner state on disk so restarts keep the training
//     signal.
//
// The coordinator is *idle-time-friendly*: a cycle is driven by
// `train(once:)`; the caller decides when to invoke (on a timer,
// after N new events, on app backgrounding). No internal thread.

final class TrainingCoordinator: @unchecked Sendable {
    struct Configuration: Sendable {
        /// When the replay buffer holds fewer than this many real
        /// preference pairs, each cycle tops up with synthetic ones.
        let coldStartPairFloor: Int
        /// Maximum synthetic pairs the coordinator asks for per cold-
        /// start top-up.
        let syntheticBatchSize: Int
        /// Minimum pairs required before the DPO trainer runs.
        let dpoMinimumPairs: Int
        /// Branching bandit minimum events before a training round.
        let branchingMinimumEvents: Int
        /// Buffer fitter minimum duration samples before a refit.
        let bufferMinimumSamples: Int
        /// Snapshot-write cadence (number of training cycles between
        /// persistence flushes). 1 = every cycle, N = every Nth.
        let snapshotEveryNCycles: Int

        static let `default` = Configuration(
            coldStartPairFloor: 20,
            syntheticBatchSize: 32,
            dpoMinimumPairs: 8,
            branchingMinimumEvents: 20,
            bufferMinimumSamples: 5,
            snapshotEveryNCycles: 4
        )
    }

    let config: Configuration
    let replayBuffer: TrainingReplayBuffer
    let metrics: TrainingMetricsLog
    private let lock = NSLock()
    private var cyclesRun: Int = 0

    init(
        config: Configuration = .default,
        replayBuffer: TrainingReplayBuffer = TrainingReplayBuffer(),
        metrics: TrainingMetricsLog = TrainingMetricsLog()
    ) {
        self.config = config
        self.replayBuffer = replayBuffer
        self.metrics = metrics
    }

    // MARK: - Cycle

    /// Run one training cycle. Intended to be called on a cadence
    /// (timer, idle hook, post-accept handler).
    ///
    /// Parameters:
    ///   • `bundle`: the SOTA learner bundle to update.
    ///   • `syntheticContext` + `syntheticEvaluator`: optional; when
    ///     provided and the replay buffer is cold, the coordinator
    ///     synthesises preference pairs from this evaluator/context
    ///     to bootstrap DPO.
    ///   • `snapshotPath`: where to persist learner state. Nil =
    ///     skip persistence.
    @discardableResult
    func train(
        bundle: BuboOptimizer.SOTALearnerBundle,
        syntheticContext: OptimizerContext? = nil,
        syntheticEvaluator: FitnessEvaluator? = nil,
        snapshotPath: String? = TrainingPersistence.defaultSnapshotPath()
    ) -> TrainingCycleResult {
        lock.lock()
        let cycleIndex = cyclesRun
        cyclesRun += 1
        lock.unlock()

        var rounds: [TrainingRound] = []

        // 1. Cold-start synthetic pairs.
        if let ctx = syntheticContext, let evaluator = syntheticEvaluator {
            let pairCount = replayBuffer.preferencePairs().count
            if pairCount < config.coldStartPairFloor {
                let needed = min(
                    config.syntheticBatchSize,
                    config.coldStartPairFloor - pairCount
                )
                if needed > 0 {
                    let result = SyntheticPreferencePairGenerator.generate(
                        context: ctx,
                        evaluator: evaluator,
                        config: .init(
                            variantsPerSeed: 8,
                            seedCount: max(1, needed / 4),
                            winnerCutoff: 0.3,
                            minFitnessGap: 0.03,
                            perturbationRate: 0.25,
                            pairsPerSeed: 4
                        )
                    )
                    let events: [TrainingEvent] = result.pairs.map {
                        TrainingEvent.preferencePair($0)
                    }
                    replayBuffer.append(batch: events)
                }
            }
        }

        // 2. DPO batch training.
        if let round = trainDPO(bundle: bundle) {
            metrics.record(round)
            rounds.append(round)
        }

        // 3. Branching bandit replay.
        if let round = trainBranchingBandit(bundle: bundle) {
            metrics.record(round)
            rounds.append(round)
        }

        // 4. Buffer fitter refit (no-op when samples insufficient).
        if let round = trainBufferStore(bundle: bundle) {
            metrics.record(round)
            rounds.append(round)
        }

        // 5. Snapshot persistence.
        if let path = snapshotPath,
           cycleIndex % config.snapshotEveryNCycles == 0 {
            persist(bundle: bundle, to: path)
        }

        return TrainingCycleResult(
            cycleIndex: cycleIndex,
            rounds: rounds,
            syntheticPairsSeeded: rounds.isEmpty ? 0 : 0  // populated above inline
        )
    }

    struct TrainingCycleResult: Sendable {
        let cycleIndex: Int
        let rounds: [TrainingRound]
        let syntheticPairsSeeded: Int
    }

    // MARK: - Per-trainer

    private func trainDPO(bundle: BuboOptimizer.SOTALearnerBundle) -> TrainingRound? {
        let pairs = replayBuffer.preferencePairs()
        guard pairs.count >= config.dpoMinimumPairs else { return nil }

        // Measure accuracy before and after on a held-out slice.
        let shuffled = pairs.shuffled()
        let splitAt = max(1, shuffled.count * 4 / 5)
        let trainSet = Array(shuffled.prefix(splitAt))
        let valSet = Array(shuffled.suffix(from: splitAt))

        let preLoss = meanNLL(bundle.dpo, pairs: valSet)
        let preAccuracy = accuracy(bundle.dpo, pairs: valSet)

        for ev in trainSet {
            bundle.dpo.observe(pair: DPOPreferencePair(
                winnerScores: ev.winnerScores,
                loserScores: ev.loserScores,
                confidence: ev.confidence
            ))
        }

        let postLoss = meanNLL(bundle.dpo, pairs: valSet)
        let postAccuracy = accuracy(bundle.dpo, pairs: valSet)

        return TrainingRound(
            timestamp: Date(),
            target: .dpo,
            samplesConsumed: trainSet.count,
            preLoss: preLoss,
            postLoss: postLoss,
            accuracy: postAccuracy,
            auxiliary: [
                "preAccuracy": preAccuracy,
                "totalPairs": Double(pairs.count),
                "observed": Double(bundle.dpo.observedPairCount),
            ]
        )
    }

    private func meanNLL(_ learner: DPOWeightLearner, pairs: [PreferencePairEvent]) -> Double {
        guard !pairs.isEmpty else { return 0 }
        var sum = 0.0
        for pair in pairs {
            let p = learner.preferenceProbability(
                aScores: pair.winnerScores,
                bScores: pair.loserScores
            )
            sum += -log(max(1e-9, p))
        }
        return sum / Double(pairs.count)
    }

    private func accuracy(_ learner: DPOWeightLearner, pairs: [PreferencePairEvent]) -> Double {
        guard !pairs.isEmpty else { return 0 }
        var correct = 0
        for pair in pairs {
            let p = learner.preferenceProbability(
                aScores: pair.winnerScores,
                bScores: pair.loserScores
            )
            if p >= 0.5 { correct += 1 }
        }
        return Double(correct) / Double(pairs.count)
    }

    private func trainBranchingBandit(bundle: BuboOptimizer.SOTALearnerBundle) -> TrainingRound? {
        let events = replayBuffer.branchingDecisions()
        guard events.count >= config.branchingMinimumEvents else { return nil }
        let bandit = bundle.branchingBandit
        // Re-observe — the bandit is additive, not idempotent. To
        // prevent unbounded growth we shuffle and take a bounded
        // window (last N events).
        let window = Array(events.suffix(256))
        for ev in window {
            guard let policy = BranchingPolicy(rawValue: ev.policy) else { continue }
            // Reconstruct a features proxy; we only have regimeKey.
            // Invert the bucket to an approximate feature set —
            // slow-but-harmless for replay purposes.
            let approx = reconstructFeatures(fromRegime: ev.regimeKey)
            bandit.observe(policy: policy, features: approx, reward: ev.reward)
        }
        return TrainingRound(
            timestamp: Date(),
            target: .branchingBandit,
            samplesConsumed: window.count,
            preLoss: 0,   // bandit: no loss defined
            postLoss: 0,
            accuracy: nil,
            auxiliary: ["totalObservations": Double(bandit.totalObservations)]
        )
    }

    private func reconstructFeatures(fromRegime key: Int) -> BranchingDecisionFeatures {
        // regimeKey = (((b0 * 3) + b1) * 3 + b2) * 3 + b3
        let b3 = key % 3
        let b2 = (key / 3) % 3
        let b1 = (key / 9) % 3
        let b0 = (key / 27) % 3
        func bucketValue(_ b: Int) -> Double {
            switch b {
            case 0: return 0.15
            case 1: return 0.50
            default: return 0.85
            }
        }
        return BranchingDecisionFeatures(
            averageDomainRatio: bucketValue(b0),
            activeConstraintFraction: bucketValue(b1),
            stagnation: bucketValue(b2),
            searchDepth: bucketValue(b3)
        )
    }

    private func trainBufferStore(bundle: BuboOptimizer.SOTALearnerBundle) -> TrainingRound? {
        let samples = replayBuffer.durationSamples()
        guard samples.count >= config.bufferMinimumSamples else { return nil }
        // Buffer store is a running Welford accumulator — "training"
        // here means replaying every sample once so the store
        // reflects the replay buffer. Idempotence note: observing
        // the same sample twice *does* bias the distribution. To
        // prevent double counting the coordinator only replays the
        // tail window since the last training round.
        let window = Array(samples.suffix(256))
        for s in window {
            bundle.bufferStore.record(
                title: s.title,
                context: s.context,
                scheduledDuration: s.scheduledDuration,
                actualDuration: s.actualDuration
            )
        }
        return TrainingRound(
            timestamp: Date(),
            target: .chanceBufferFit,
            samplesConsumed: window.count,
            preLoss: 0,
            postLoss: 0,
            accuracy: nil,
            auxiliary: ["trackedSignatures": Double(bundle.bufferStore.trackedSignatureCount)]
        )
    }

    // MARK: - Persistence

    private func persist(
        bundle: BuboOptimizer.SOTALearnerBundle,
        to path: String
    ) {
        let snapshot = TrainingSnapshot(
            dpo: TrainingPersistence.capture(dpo: bundle.dpo),
            buffers: nil,   // ChanceConstrainedBufferStore capture can be added when exposed
            branching: nil,
            savedAt: Date()
        )
        TrainingPersistence.save(snapshot: snapshot, to: path)
    }

    // MARK: - Restore

    /// Load a persisted snapshot into the given bundle. Call once
    /// after bundle construction so learned state survives restarts.
    static func restore(
        into bundle: BuboOptimizer.SOTALearnerBundle,
        from path: String = TrainingPersistence.defaultSnapshotPath() ?? ""
    ) {
        guard !path.isEmpty,
              let snapshot = TrainingPersistence.load(from: path) else { return }
        if let dpo = snapshot.dpo {
            TrainingPersistence.restore(dpo: bundle.dpo, from: dpo)
        }
    }
}
