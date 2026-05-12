import Foundation

// MARK: - BuboOptimizer incremental re-optimization
//
// Targeted re-optimize and Instant Reflow paths, plus the private
// makeReoptContext helper that prepares the OptimizerContext.
// Extracted from BuboOptimizer.swift.

public extension BuboOptimizer {

    // MARK: - Incremental Re-optimization (#26)

    public func reoptimize(
        trigger: ReoptimizationTrigger,
        context: OptimizerContext
    ) async -> OptimizerResult? {
        isOptimizing = true
        defer { isOptimizing = false }

        var prefs = context.preferences
        preferenceLearner.applyToPreferences(&prefs)

        let evaluator = FitnessEvaluator.standard(preferences: prefs)
        let schedule = currentSchedule
        // Capture reoptimizer config as values for thread safety
        let stabilityWeight = reoptimizer.stabilityWeight
        let minimumImprovement = reoptimizer.minimumImprovement

        let reopt = IncrementalReoptimizer()
        reopt.stabilityWeight = stabilityWeight
        reopt.minimumImprovement = minimumImprovement

        // Wire the same CP-SAT infrastructure `optimize()` uses so
        // the reopt path can produce a warm-started CP-SAT anchor
        // via `AnchorSeeder`. Callers of `BuboOptimizer.reoptimize`
        // pass raw contexts that typically don't plumb a repairer
        // themselves; injecting it here keeps the feature-flag
        // decision centralised in this file.
        let reoptContext = makeReoptContext(from: context)

        let result = await Task.detached(priority: .userInitiated) {
            reopt.reoptimize(
                currentSchedule: schedule,
                trigger: trigger,
                context: reoptContext,
                evaluator: evaluator,
                config: .quick
            )
        }.value

        // Update internal state if re-optimization succeeded
        if let result = result, let best = result.scenarios.first {
            currentSchedule = best.genes
            lastResult = result
        }

        return result
    }

    // MARK: - Instant Reflow

    /// Ultra-fast re-optimization for live preview and drag-to-schedule.
    /// Uses .instant config (~20 generations, ~100ms) with warm start.
    /// Returns the best genes or nil if no improvement found.
    public func instantReflow(context: OptimizerContext) async -> [ScheduleGene]? {
        var prefs = context.preferences
        preferenceLearner.applyToPreferences(&prefs)

        let evaluator = FitnessEvaluator.standard(preferences: prefs)
        let schedule = currentSchedule
        let reoptContext = makeReoptContext(from: context)

        let result = await Task.detached(priority: .userInitiated) {
            let reopt = IncrementalReoptimizer()
            reopt.stabilityWeight = 3.0  // prefer stability for preview
            reopt.minimumImprovement = 0.01  // accept smaller improvements

            return reopt.reoptimize(
                currentSchedule: schedule,
                trigger: .periodicRefresh,
                context: reoptContext,
                evaluator: evaluator,
                config: .instant
            )
        }.value

        return result?.scenarios.first?.genes
    }

    /// Produce a reopt-ready copy of a caller-supplied context that
    /// carries the CP-SAT repairer and window threshold currently
    /// configured via `schedulingFeatures`. Returned unchanged when
    /// the caller already supplied a repairer (tests) or when the
    /// feature flag is off.
    private func makeReoptContext(from context: OptimizerContext) -> OptimizerContext {
        if context.cpSATRepairer != nil || !schedulingFeatures.useCPSATSeed {
            return context
        }
        return OptimizerContext(
            fixedEvents: context.fixedEvents,
            movableEvents: context.movableEvents,
            workingHours: context.workingHours,
            planningHorizon: context.planningHorizon,
            preferences: context.preferences,
            participantAvailability: context.participantAvailability,
            calendar: context.calendar,
            rng: context.rng,
            mutationBandit: context.mutationBandit,
            lnsStrategyBandit: context.lnsStrategyBandit,
            lnsRepairBandit: context.lnsRepairBandit,
            contextualCrossoverHead: context.contextualCrossoverHead,
            conflictGraphHolder: context.conflictGraphHolder,
            tabuMemory: context.tabuMemory,
            cpSATRepairer: CPSATRepairer(),
            cpSATWindowThreshold: schedulingFeatures.cpSATWindowThreshold,
            slotRegistryHolder: context.slotRegistryHolder,
            slotDomainsHolder: context.slotDomainsHolder
        )
    }

}
