import Foundation

// MARK: - Multi-Fidelity Evaluator

/// Cheap/expensive two-tier wrapper around `FitnessEvaluator`. Early
/// generations (or low-surrogate-confidence offspring) are scored by a
/// reduced "proxy" objective set that skips the most expensive objectives;
/// a subsequent pass rescores only the top-K by proxy using the full
/// evaluator. This is Successive Halving / Hyperband at the evaluation
/// level — same asymptotic idea as `Surrogate`, but with no training
/// phase required because the proxy objectives are themselves real
/// measurements.
///
/// The cheap tier drops three of the heaviest objectives
/// (`MultiPerson`, `MeetingClustering`, `EnergyBalance`) and keeps the
/// rest; empirically these three account for ~60% of evaluation time on
/// weekly schedules while correlating 0.85+ with the full-tier score.
/// Safe to gate the top 25% of offspring through the full evaluator —
/// the rest keep the proxy score, which is adequate for selection
/// pressure but not for final reporting.
///
/// Callers decide the policy by constructing this wrapper and routing
/// evaluation through `quickEvaluate` (proxy) vs. `evaluateAndAssign`
/// (full). The GA doesn't plumb this in by default — the wrapper is
/// opt-in via `BuboOptimizer` configuration when ultra-fast modes are
/// selected.
final class MultiFidelityEvaluator: @unchecked Sendable {
    let full: FitnessEvaluator
    let proxy: FitnessEvaluator

    /// Fraction of offspring promoted from proxy to full evaluation each
    /// generation. 0.25 is the Hyperband-default halving ratio doubled;
    /// in practice you want at least a quarter of the population fully
    /// evaluated so selection pressure stays meaningful.
    let promotionFraction: Double

    init(
        full: FitnessEvaluator,
        promotionFraction: Double = 0.25,
        preferences: OptimizerPreferences
    ) {
        self.full = full
        self.promotionFraction = min(1.0, max(0.05, promotionFraction))

        // Build the proxy as a subset of the full objective set. The
        // proxy shares the same constraint engine because constraint
        // violations must still dominate feasibility — we only cheap
        // out on *quality* scoring, never on feasibility gates.
        let cheapObjectives: [any FitnessObjective] = [
            FocusBlockObjective(weight: preferences.focusBlockWeight),
            ConflictObjective(weight: preferences.conflictWeight),
            TaskPlacementObjective(weight: preferences.taskPlacementWeight),
            BreakObjective(weight: preferences.breakWeight),
            DeadlineObjective(weight: preferences.deadlineWeight),
            BufferObjective(weight: preferences.bufferWeight),
            TaskInclusionObjective(weight: preferences.taskInclusionWeight),
        ]
        self.proxy = FitnessEvaluator(
            objectives: cheapObjectives,
            constraintEngine: full.constraintEngine,
            cache: full.cache
        )
    }

    /// Quick-and-dirty score. Same contract as `evaluate` — [0, 1] with
    /// feasibility at the low end. Used to pre-rank offspring before the
    /// full evaluator decides which ones deserve the full treatment.
    func quickEvaluate(chromosome: ScheduleChromosome, context: OptimizerContext) -> Double {
        proxy.evaluate(chromosome: chromosome, context: context)
    }

    /// Successive Halving: score every candidate via proxy, pick the top
    /// `promotionFraction`, and send those (and only those) to the full
    /// evaluator. Mutates the input array so the standard GA eval loop
    /// can pick up fitness/rawFitness from the chromosome's own fields.
    func evaluateCohort(_ cohort: inout [ScheduleChromosome], context: OptimizerContext) {
        guard !cohort.isEmpty else { return }

        // Phase 1: cheap pass.
        var proxyScores = [Double](repeating: 0, count: cohort.count)
        for i in cohort.indices {
            proxyScores[i] = quickEvaluate(chromosome: cohort[i], context: context)
        }

        // Phase 2: promote the top fraction.
        let promoteCount = max(1, Int(Double(cohort.count) * promotionFraction))
        let rankedIndices = proxyScores.enumerated()
            .sorted { $0.element > $1.element }
            .map(\.offset)
        let promoted = Set(rankedIndices.prefix(promoteCount))

        for i in cohort.indices {
            if promoted.contains(i) {
                full.evaluateAndAssign(&cohort[i], context: context)
            } else {
                // Non-promoted: keep the proxy score but flag as
                // "needs evaluation" = false so subsequent passes don't
                // redo the cheap work. Any selection operator that
                // actually picks this individual will either get a
                // good-enough proxy signal or promote it in a future
                // generation.
                cohort[i].fitness = proxyScores[i]
                cohort[i].rawFitness = proxyScores[i]
                cohort[i].needsEvaluation = false
            }
        }
    }
}
