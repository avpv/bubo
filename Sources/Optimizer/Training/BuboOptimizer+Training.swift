import Foundation

// MARK: - BuboOptimizer Training Wiring
//
// Wires the autonomous training pipeline (TrainingReplayBuffer +
// TrainingCoordinator + TrainingMetrics) into BuboOptimizer's
// feedback surface. Every accept/reject/modify and every recorded
// event duration append a training event, so the replay buffer
// grows automatically during normal app use.
//
// The actual training *cycle* runs on demand via
// `runTrainingCycle(...)`. The host app typically calls it:
//   • On app backgrounding / idle detection.
//   • After every N accepts (default 8).
//   • On an explicit "Improve model now" user action.
// No internal timer — the coordinator is synchronous and returns
// quickly enough to be called from any thread.

fileprivate final class TrainingState: @unchecked Sendable {
    public let replayBuffer: TrainingReplayBuffer
    public let coordinator: TrainingCoordinator
    public let metrics: TrainingMetricsLog
    public var acceptsSinceLastTraining: Int = 0
    public var restoredOnce: Bool = false

    public init() {
        let buffer = TrainingReplayBuffer()
        let metrics = TrainingMetricsLog()
        self.replayBuffer = buffer
        self.metrics = metrics
        self.coordinator = TrainingCoordinator(
            replayBuffer: buffer,
            metrics: metrics
        )
    }
}

fileprivate let trainingStateStore = TrainingStateStore()

fileprivate final class TrainingStateStore: @unchecked Sendable {
    private var store: [ObjectIdentifier: TrainingState] = [:]
    private let lock = NSLock()

    public func load(key: ObjectIdentifier) -> TrainingState {
        lock.lock()
        defer { lock.unlock() }
        if let existing = store[key] { return existing }
        let fresh = TrainingState()
        store[key] = fresh
        return fresh
    }
}

public extension BuboOptimizer {

    // MARK: - Public surface

    /// Access to the replay buffer — inspectable for debugging.
    var trainingReplayBuffer: TrainingReplayBuffer {
        trainingStateStore.load(key: ObjectIdentifier(self)).replayBuffer
    }

    /// Access to the metrics log.
    var trainingMetrics: TrainingMetricsLog {
        trainingStateStore.load(key: ObjectIdentifier(self)).metrics
    }

    /// After this many accepts, call `runTrainingCycle` automatically.
    var trainingAcceptCadence: Int { 8 }

    // MARK: - Event recording

    /// Record a user accept event. Invoked from `acceptScenario`.
    func trainingRecordAccept(
        accepted: ScheduleScenario,
        runnerUps: [ScheduleScenario]
    ) {
        let state = trainingStateStore.load(key: ObjectIdentifier(self))
        for loser in runnerUps {
            let event = PreferencePairEvent(
                timestamp: Date(),
                winnerScores: accepted.objectiveBreakdown,
                loserScores: loser.objectiveBreakdown,
                confidence: 1.0,
                source: .userAccept
            )
            state.replayBuffer.append(.preferencePair(event))
        }
        state.acceptsSinceLastTraining += 1
        if state.acceptsSinceLastTraining >= trainingAcceptCadence {
            state.acceptsSinceLastTraining = 0
            _ = runTrainingCycle()
        }
    }

    /// Record a user reject event as a preference for the top fit
    /// scenario over the rejected one.
    func trainingRecordReject(
        rejected: ScheduleScenario,
        allScenarios: [ScheduleScenario]
    ) {
        guard let top = allScenarios.first(where: { $0.id != rejected.id }) else { return }
        let state = trainingStateStore.load(key: ObjectIdentifier(self))
        let event = PreferencePairEvent(
            timestamp: Date(),
            winnerScores: top.objectiveBreakdown,
            loserScores: rejected.objectiveBreakdown,
            confidence: 0.8,
            source: .userReject
        )
        state.replayBuffer.append(.preferencePair(event))
    }

    // `trainingRecordBranching` was retired along with the
    // LearnedBranchingBandit that consumed its events.

    /// Record an event's scheduled-vs-actual duration. Called by
    /// the host when an event finishes. Merges into both the live
    /// buffer store (via `recordEventDurationSample`) and the replay
    /// buffer so training cycles can re-fit.
    func trainingRecordDurationSample(
        title: String,
        scenarioContext: String?,
        scheduledDuration: TimeInterval,
        actualDuration: TimeInterval,
        workloadContext: OptimizerContext
    ) {
        let state = trainingStateStore.load(key: ObjectIdentifier(self))
        let event = DurationSampleEvent(
            timestamp: Date(),
            title: title,
            context: scenarioContext,
            scheduledDuration: scheduledDuration,
            actualDuration: actualDuration
        )
        state.replayBuffer.append(.durationSample(event))
        recordEventDurationSample(
            title: title,
            context: scenarioContext,
            scheduledDuration: scheduledDuration,
            actualDuration: actualDuration,
            workloadContext: workloadContext
        )
    }

    // MARK: - Cycle trigger

    /// Run one training cycle. Uses the last optimization's context
    /// for cold-start synthetic pair generation when available. Safe
    /// to call from any thread — internally synchronous, returns
    /// quickly.
    @discardableResult
    func runTrainingCycle() -> TrainingCoordinator.TrainingCycleResult? {
        let state = trainingStateStore.load(key: ObjectIdentifier(self))
        guard let ctx = lastOptimizationContext else {
            return nil
        }
        let bundle = obtainLearnerSuite(for: ctx)
        // Restore persisted state once per process.
        if !state.restoredOnce {
            if let path = TrainingPersistence.defaultSnapshotPath() {
                TrainingCoordinator.restore(into: bundle, from: path)
            }
            state.restoredOnce = true
        }
        let evaluator = FitnessEvaluator.standard(preferences: ctx.preferences)
        return state.coordinator.train(
            bundle: bundle,
            syntheticContext: ctx,
            syntheticEvaluator: evaluator
        )
    }

    /// Explicit restore entry — call on app launch to load the
    /// on-disk snapshot into the learner bundle of the currently
    /// active workload.
    func restoreTrainingState(for context: OptimizerContext) {
        let state = trainingStateStore.load(key: ObjectIdentifier(self))
        guard !state.restoredOnce else { return }
        let bundle = obtainLearnerSuite(for: context)
        if let path = TrainingPersistence.defaultSnapshotPath() {
            TrainingCoordinator.restore(into: bundle, from: path)
        }
        state.restoredOnce = true
    }
}
