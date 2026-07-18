import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - Training Pipeline Tests

@Suite("Training replay buffer")
struct TrainingReplayBufferTests {
    @Test("append and read back preference pairs")
    func appendPreference() {
        let buf = TrainingReplayBuffer(config: .memoryOnly)
        let event = PreferencePairEvent(
            timestamp: Date(),
            winnerScores: ["A": 1.0],
            loserScores: ["A": 0.0],
            confidence: 1.0,
            source: .userAccept
        )
        buf.append(.preferencePair(event))
        let pairs = buf.preferencePairs()
        #expect(pairs.count == 1)
        #expect(pairs.first?.source == .userAccept)
    }

    @Test("capacity evicts FIFO")
    func capacityEvicts() {
        let buf = TrainingReplayBuffer(config: .init(
            capacity: 3, storagePath: nil, flushEveryN: 0
        ))
        for i in 0..<5 {
            buf.append(.durationSample(DurationSampleEvent(
                timestamp: Date(),
                title: "m\(i)",
                context: nil,
                scheduledDuration: 1800,
                actualDuration: 1900
            )))
        }
        #expect(buf.count == 3)
    }

    @Test("separate views per event kind")
    func separateViews() {
        let buf = TrainingReplayBuffer(config: .memoryOnly)
        buf.append(.preferencePair(PreferencePairEvent(
            timestamp: Date(), winnerScores: [:], loserScores: [:],
            confidence: 1.0, source: .synthetic
        )))
        buf.append(.durationSample(DurationSampleEvent(
            timestamp: Date(), title: "x", context: nil,
            scheduledDuration: 60, actualDuration: 90
        )))
        #expect(buf.preferencePairs().count == 1)
        #expect(buf.durationSamples().count == 1)
        #expect(buf.branchingDecisions().isEmpty)
    }
}

@Suite("Synthetic preference pair generator")
struct SyntheticPairGeneratorTests {
    @Test("generates non-empty pairs under normal config")
    func generatesPairs() {
        let events = (0..<5).map { i in
            OptimizableEvent(
                id: "E\(i)",
                title: "E\(i)",
                duration: 3600,
                priority: 0.5 + Double(i) * 0.05
            )
        }
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: ctx.preferences)
        let result = SyntheticPreferencePairGenerator.generate(
            context: ctx,
            evaluator: evaluator,
            config: .init(
                variantsPerSeed: 6,
                seedCount: 2,
                winnerCutoff: 0.4,
                minFitnessGap: 0.0,
                perturbationRate: 0.3,
                pairsPerSeed: 3
            )
        )
        #expect(!result.pairs.isEmpty)
        #expect(result.variantsSampled == 12)
    }

    @Test("every pair tagged synthetic")
    func syntheticSource() {
        let events = (0..<3).map { OptimizerTestFixtures.makeEvent(id: "E\($0)") }
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: ctx.preferences)
        let result = SyntheticPreferencePairGenerator.generate(
            context: ctx, evaluator: evaluator
        )
        for pair in result.pairs {
            #expect(pair.source == .synthetic)
        }
    }
}

@Suite("Training metrics log")
struct TrainingMetricsLogTests {
    @Test("records rounds and produces summary")
    func summary() {
        let log = TrainingMetricsLog()
        log.record(TrainingRound(
            timestamp: Date(),
            target: .dpo,
            samplesConsumed: 10,
            preLoss: 0.8,
            postLoss: 0.5,
            accuracy: 0.7,
            auxiliary: [:]
        ))
        log.record(TrainingRound(
            timestamp: Date(),
            target: .dpo,
            samplesConsumed: 15,
            preLoss: 0.5,
            postLoss: 0.3,
            accuracy: 0.85,
            auxiliary: [:]
        ))
        let summary = log.summaryByTarget()[.dpo]
        #expect(summary?.rounds == 2)
        #expect(summary?.samples == 25)
        #expect((summary?.meanAccuracy ?? 0) > 0.7)
    }

    @Test("capacity trims oldest rounds")
    func capacityTrim() {
        let log = TrainingMetricsLog(config: .init(capacity: 2))
        for i in 0..<5 {
            log.record(TrainingRound(
                timestamp: Date(),
                target: .dpo,
                samplesConsumed: i,
                preLoss: 1, postLoss: 0.5,
                accuracy: nil, auxiliary: [:]
            ))
        }
        let kept = log.rounds(since: Date.distantPast)
        #expect(kept.count == 2)
    }
}

// @MainActor: `BuboOptimizer.AdaptiveLearnerSuite` is nested in a
// @MainActor class and inherits its isolation, so the synchronous
// `AdaptiveLearnerSuite()` constructions below need a main-actor
// context to compile.
@MainActor
@Suite("Training coordinator")
struct TrainingCoordinatorTests {
    @Test("cold-start generates synthetic pairs")
    func coldStartGenerates() {
        let buffer = TrainingReplayBuffer(config: .memoryOnly)
        let coordinator = TrainingCoordinator(
            config: .init(
                coldStartPairFloor: 10,
                syntheticBatchSize: 12,
                dpoMinimumPairs: 4,
                branchingMinimumEvents: 100,
                bufferMinimumSamples: 100,
                snapshotEveryNCycles: 100
            ),
            replayBuffer: buffer
        )
        let events = (0..<3).map { OptimizerTestFixtures.makeEvent(id: "E\($0)") }
        let ctx = OptimizerTestFixtures.makeContext(movableEvents: events)
        let evaluator = FitnessEvaluator.standard(preferences: ctx.preferences)
        let bundle = BuboOptimizer.AdaptiveLearnerSuite()

        let result = coordinator.train(
            bundle: bundle,
            syntheticContext: ctx,
            syntheticEvaluator: evaluator,
            snapshotPath: nil
        )
        #expect(buffer.preferencePairs().count > 0)
        _ = result
    }

    @Test("no cycle runs below minimum pairs without synthetic context")
    func noCycleBelowMinimum() {
        let buffer = TrainingReplayBuffer(config: .memoryOnly)
        let coordinator = TrainingCoordinator(
            config: .init(
                coldStartPairFloor: 0,
                syntheticBatchSize: 0,
                dpoMinimumPairs: 50,
                branchingMinimumEvents: 100,
                bufferMinimumSamples: 100,
                snapshotEveryNCycles: 100
            ),
            replayBuffer: buffer
        )
        let bundle = BuboOptimizer.AdaptiveLearnerSuite()
        let result = coordinator.train(
            bundle: bundle,
            syntheticContext: nil,
            syntheticEvaluator: nil,
            snapshotPath: nil
        )
        #expect(result.rounds.isEmpty)
    }

    @Test("DPO training round populates metrics")
    func dpoPopulatesMetrics() {
        let buffer = TrainingReplayBuffer(config: .memoryOnly)
        // Seed with real pairs.
        for i in 0..<30 {
            let event = PreferencePairEvent(
                timestamp: Date(),
                winnerScores: ["Deadline": 1.0, "FocusBlock": 0.5],
                loserScores: ["Deadline": 0.0, "FocusBlock": 0.5],
                confidence: 1.0,
                source: .userAccept
            )
            buffer.append(.preferencePair(event))
            _ = i
        }
        let metrics = TrainingMetricsLog()
        let coordinator = TrainingCoordinator(
            config: .init(
                coldStartPairFloor: 0,
                syntheticBatchSize: 0,
                dpoMinimumPairs: 10,
                branchingMinimumEvents: 100,
                bufferMinimumSamples: 100,
                snapshotEveryNCycles: 100
            ),
            replayBuffer: buffer,
            metrics: metrics
        )
        let bundle = BuboOptimizer.AdaptiveLearnerSuite()
        _ = coordinator.train(
            bundle: bundle,
            syntheticContext: nil,
            syntheticEvaluator: nil,
            snapshotPath: nil
        )
        let dpoSummary = metrics.summaryByTarget()[.dpo]
        #expect(dpoSummary?.rounds == 1)
    }
}

@Suite("Training persistence")
struct TrainingPersistenceTests {
    @Test("round-trips DPO weights")
    func dpoRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bubo_snapshot_\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let learner = DPOWeightLearner(priorWeights: ["A": 1.5, "B": 0.3])
        let captured = TrainingPersistence.capture(dpo: learner)
        let snapshot = TrainingSnapshot(
            dpo: captured,
            buffers: nil,
            branching: nil,
            savedAt: Date()
        )
        TrainingPersistence.save(snapshot: snapshot, to: tmp)
        let loaded = TrainingPersistence.load(from: tmp)
        #expect(loaded?.dpo?.weights["A"] == 1.5)
        #expect(loaded?.dpo?.weights["B"] == 0.3)
    }

    @Test("load returns nil for missing file")
    func missingFile() {
        let path = "/tmp/definitely-not-a-real-snapshot-\(UUID().uuidString).json"
        #expect(TrainingPersistence.load(from: path) == nil)
    }
}
