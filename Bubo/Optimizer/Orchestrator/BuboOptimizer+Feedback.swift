import Foundation

// MARK: - BuboOptimizer user-feedback hooks
//
// Accept / reject / record-manual-edit entry points that route a
// per-scenario reward back into the workload's learner bundle (bandit,
// attention head, surrogate), plus the small `ScenarioComparer` façade.
// Extracted from `BuboOptimizer.swift` so the feedback path lives next
// to its private dispatch helpers (`bundle(for:)`,
// `propagateFeedbackReward(_:scenario:)`) rather than buried at the
// bottom of the main file.

extension BuboOptimizer {

    // MARK: - User Feedback (#24)
    //
    // Feedback fans out to three learners:
    //   • `PreferenceLearner` — evolves per-objective weights via its
    //     meta-GA (unchanged, instance-level by design).
    //   • The per-workload `MutationBandit` — bounded LinUCB reward
    //     per operator nudges arm estimates so operators that
    //     produced accepted schedules get reinforced on subsequent
    //     runs *of the same workload*.
    //   • The per-workload `GeneAttentionHead` — a small weight step
    //     biases contextual crossover toward / away from patterns
    //     associated with accepted / rejected results.
    //
    // Routing: feedback methods read `scenario.sourceSignature` and
    // look up the matching learner bundle. This is robust under
    // multiple optimizations on different workloads — a manual edit
    // on a stale scenario from workload A correctly updates A's
    // bundle even after runs B, C have happened since. Falls back
    // to silent no-op for scenarios with no `sourceSignature` (e.g.
    // hand-built fixtures).
    //
    // Update magnitude is intentionally small (~0.1) so one noisy
    // feedback event doesn't dominate learned state; many events
    // converge.
    //
    // Known limitation: `recordManualEdit` receives `original` and
    // `edited` gene arrays but currently only uses the act of
    // editing as a global "close but not right" signal. The
    // semantic *diff* (which genes the user moved, by how much) is
    // not yet pulled into per-operator credit assignment — a future
    // refinement that would require lineage tracking per offspring.

    func acceptScenario(_ scenario: ScheduleScenario) {
        currentSchedule = scenario.genes
        preferenceLearner.recordAcceptance(scenarioFitness: scenario.fitness)
        propagateFeedbackReward(+0.1, scenario: scenario)
        // Propagate acceptance to adaptive learners: DPO + temporal warm-start
        // using whichever other scenarios from the last run act as
        // implicit runner-ups.
        let runnerUps: [ScheduleScenario] = (lastResult?.scenarios ?? [])
            .filter { $0.id != scenario.id }
        propagateAcceptFeedback(
            accepted: scenario,
            runnerUps: runnerUps,
            context: lastOptimizationContext
        )
        // Training pipeline: append to replay buffer; may trigger a
        // training cycle once the accept cadence threshold is hit.
        trainingRecordAccept(accepted: scenario, runnerUps: runnerUps)
    }

    func rejectScenario(_ scenario: ScheduleScenario) {
        preferenceLearner.recordRejection(scenarioFitness: scenario.fitness)
        propagateFeedbackReward(-0.1, scenario: scenario)
        // Model a rejection as a preference against the rejected vs.
        // the top-fitness alternative. Cheap source of DPO signal.
        if let best = lastResult?.scenarios.first, best.id != scenario.id,
           let bundle = lookupLearnerSuite(for: scenario),
           schedulingFeatures.useDPOWeightLearning {
            bundle.dpo.observe(pair: DPOPreferencePair(
                winnerScores: best.objectiveBreakdown,
                loserScores: scenario.objectiveBreakdown,
                confidence: 1.0
            ))
        }
        trainingRecordReject(
            rejected: scenario,
            allScenarios: lastResult?.scenarios ?? []
        )
    }

    func recordManualEdit(scenario: ScheduleScenario, edited: [ScheduleGene]) {
        currentSchedule = edited
        preferenceLearner.recordModification(original: scenario.genes, edited: edited)
        guard let bundle = bundle(for: scenario) else { return }
        for op in MutationOperator.allCases {
            bundle.bandit.record(op: op, reward: -0.03)
        }
        bundle.head.updateWeights(features: [1, 1, 1, 1, 1], rewardSign: -0.3)
    }

    /// Backwards-compatible overload accepting raw gene arrays. Use
    /// the `scenario`-typed overload when you have a `ScheduleScenario`
    /// in hand — it correctly routes feedback by `sourceSignature`.
    /// This overload routes via `lastRunSignature` (correct only when
    /// no later optimizations have happened).
    func recordManualEdit(original: [ScheduleGene], edited: [ScheduleGene]) {
        currentSchedule = edited
        preferenceLearner.recordModification(original: original, edited: edited)
        guard let signature = lastRunSignature,
              let bundle = learnersBySignature[signature] else { return }
        for op in MutationOperator.allCases {
            bundle.bandit.record(op: op, reward: -0.03)
        }
        bundle.head.updateWeights(features: [1, 1, 1, 1, 1], rewardSign: -0.3)
    }

    /// Resolve the learner bundle a scenario refers to. Prefers
    /// `scenario.sourceSignature` (set by `optimize()`). Falls back to
    /// `lastRunSignature` for hand-built scenarios that have no
    /// signature stamped.
    private func bundle(for scenario: ScheduleScenario) -> WorkloadLearners? {
        let key = scenario.sourceSignature ?? lastRunSignature
        guard let key else { return nil }
        return learnersBySignature[key]
    }

    /// Apply a uniform reward signal to every bandit arm and a
    /// scenario-magnitude-scaled nudge to the attention head, for
    /// the workload that produced the scenario. Uniform across
    /// operators because we don't retain per-gene lineage; LinUCB's
    /// context features already discriminate regimes, so "reinforce
    /// whatever you were doing" averages out over many feedback
    /// events.
    private func propagateFeedbackReward(_ reward: Double, scenario: ScheduleScenario) {
        guard let bundle = bundle(for: scenario) else { return }
        for op in MutationOperator.allCases {
            bundle.bandit.record(op: op, reward: reward)
        }
        let rewardSign: Double = reward == 0 ? 0 : (reward < 0 ? -1 : 1)
        let signedMagnitude = rewardSign * max(0.3, scenario.fitness)
        bundle.head.updateWeights(features: [1, 1, 1, 1, 1], rewardSign: signedMagnitude)
    }

    // MARK: - Scenario Comparison (#27)

    func compareLastScenarios() -> [ScenarioComparison] {
        guard let result = lastResult else { return [] }
        return ScenarioComparer.compare(result.scenarios)
    }
}
