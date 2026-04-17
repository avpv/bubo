import Foundation

// MARK: - BuboOptimizer

/// Main facade for the Bubo schedule optimization engine.
/// Combines GA core, constraints, objectives, re-optimization,
/// scenario generation, and preference learning into a single API.
///
/// All optimization methods are async and run the GA on a background thread
/// to keep the main thread responsive.
@MainActor
@Observable
final class BuboOptimizer {

    // MARK: - Components

    let preferenceLearner = PreferenceLearner()
    let reoptimizer = IncrementalReoptimizer()

    /// Number of scenarios to return per optimization.
    var scenarioCount: Int = 3

    // MARK: - Learned State (persists across optimize() calls)

    /// Per-instance mutation bandit. Instance-level (not per-run) so
    /// reinforcement from user feedback carries into subsequent
    /// optimizations. LinUCB's contextual features (diversity,
    /// stagnation, imbalance) already discriminate regimes, so
    /// cross-workload bleed is bounded.
    let mutationBandit: MutationBandit = MutationBandit()

    /// Per-instance attention head. Same rationale as `mutationBandit`:
    /// user feedback nudges weights across runs.
    let contextualCrossoverHead: GeneAttentionHead = GeneAttentionHead()

    // MARK: - State

    private(set) var isOptimizing = false
    private(set) var lastResult: OptimizerResult?

    /// The current schedule genes (movable events placement).
    var currentSchedule: [ScheduleGene] = []

    // MARK: - Configuration

    var gaConfig: GAConfiguration = .default
    var islandConfig: IslandConfiguration = .default
    var preferences: OptimizerPreferences = OptimizerPreferences()

    // MARK: - Full Optimization (Async)

    /// Run a full optimization for the given context.
    /// Uses island model GA with multiple parallel populations and periodic migration.
    /// The GA runs on a background thread; progress updates are dispatched to main.
    func optimize(
        context: OptimizerContext,
        overrideConfig: GAConfiguration? = nil,
        overrideIslandConfig: IslandConfiguration? = nil
    ) async -> OptimizerResult {
        isOptimizing = true
        defer { isOptimizing = false }

        // Apply learned preferences, merging with (not replacing) user preferences
        var prefs = context.preferences
        preferenceLearner.applyToPreferences(&prefs)

        // Wire fresh per-run learners. Bandit/attention-head stats don't
        // carry over between optimizations because workload
        // characteristics (fixed events, movable pool, preferences)
        // differ per run; stale weights would be actively misleading.
        //
        // RNG is *split* from the caller's generator, not shared:
        // `GARandom` is a reference type, and two concurrent
        // `optimize()` calls on the same BuboOptimizer would otherwise
        // interleave draws from a single stream. The split keeps the
        // caller's stream reproducible across concurrent runs.
        let adjustedContext = OptimizerContext(
            fixedEvents: context.fixedEvents,
            movableEvents: context.movableEvents,
            workingHours: context.workingHours,
            planningHorizon: context.planningHorizon,
            preferences: prefs,
            participantAvailability: context.participantAvailability,
            calendar: context.calendar,
            rng: context.rng.split(),
            mutationBandit: mutationBandit,
            contextualCrossoverHead: contextualCrossoverHead
        )

        let evaluator = FitnessEvaluator.standard(preferences: prefs)
        let config = overrideConfig ?? gaConfig
        let capturedIslandConfig = overrideIslandConfig ?? islandConfig
        let capturedScenarioCount = scenarioCount

        // Adaptive NSGA-III + HypE-lite survivor selector. Reads
        // per-objective scores from the chromosome cache so survivor
        // selection imposes zero extra evaluation cost.
        let multiObjective = MultiObjectiveContext<ScheduleChromosome>.schedule(
            evaluator: evaluator,
            populationSize: config.populationSize
        )

        // Quality-Diversity archive shared across every island so
        // productive genotypes discovered anywhere feed every
        // population.
        let qdArchive = QualityDiversityArchive(resolution: 6)

        // Gradient refiner for elite fine-tuning. Pure value type;
        // safe to capture across threads.
        let gradientRefiner = ScheduleGradientRefiner()

        // Surrogate model — predicts fitness for offspring whose
        // features sit close to recently-evaluated samples. Real
        // evaluator runs on warm-up samples and on uncertain queries.
        let surrogate = RBFSurrogate()

        // Canonical objective ordering for surrogate's objective-vector
        // prediction. Must match the order `MultiObjectiveContext`
        // reads from `objectiveCache`, else NSGA-III associates
        // surrogate-predicted individuals with the wrong reference
        // directions.
        let objectiveNames = evaluator.objectives.map(\.name)

        // Schedule-specific evolution hooks. Composed via the generic
        // `EvolutionHooks` API so the engine never sees schedule types.
        //
        // The evaluator does two things differently from the baseline
        // path:
        //   (1) On surrogate-accept, it fills `objectiveCache` with a
        //       predicted objective vector so NSGA-III / hypervolume
        //       selection sees non-zero per-axis scores. Without this,
        //       surrogate-predicted individuals land on front 0 with
        //       a phantom-perfect Pareto position.
        //   (2) On calibration refresh / high-uncertainty real
        //       evaluation, it passes the surrogate's pre-call
        //       prediction back via `priorPrediction` so rolling MAE
        //       in telemetry actually tracks drift.
        let surrogateAssistedEvaluator: @Sendable (inout ScheduleChromosome) -> Void = { chromosome in
            let features = ScheduleFeatureVector.extract(chromosome, context: adjustedContext).values
            switch surrogate.screen(features: features) {
            case .accept(let predicted, let predictedObjectives):
                chromosome.fitness = predicted
                chromosome.rawFitness = predicted
                chromosome.needsEvaluation = false
                if let vec = predictedObjectives, vec.count == objectiveNames.count {
                    var cache: [String: Double] = [:]
                    cache.reserveCapacity(objectiveNames.count)
                    for (i, name) in objectiveNames.enumerated() {
                        cache[name] = vec[i]
                    }
                    chromosome.objectiveCache = cache
                }
            case .realEvaluate(_, let priorPrediction):
                evaluator.evaluateAndAssign(&chromosome, context: adjustedContext)
                let objectivesVec: ContiguousArray<Double>?
                if let cache = chromosome.objectiveCache {
                    var v = ContiguousArray<Double>()
                    v.reserveCapacity(objectiveNames.count)
                    for name in objectiveNames {
                        v.append(cache[name] ?? 0)
                    }
                    objectivesVec = v
                } else {
                    objectivesVec = nil
                }
                surrogate.record(
                    features: features,
                    fitness: chromosome.rawFitness,
                    objectives: objectivesVec,
                    priorPrediction: priorPrediction
                )
            }
        }

        let hooks = ScheduleEvolutionHooks.compose(
            ScheduleEvolutionHooks.qualityDiversityFeeding(archive: qdArchive),
            ScheduleEvolutionHooks.qualityDiversityEmission(archive: qdArchive, emissionRate: 0.12),
            ScheduleEvolutionHooks.gradientRefinement(
                refiner: gradientRefiner,
                interval: 35,
                candidates: 3,
                evaluate: surrogateAssistedEvaluator
            )
        )

        // Run island model GA on background thread. All islands share
        // the instance-level `mutationBandit` and `contextualCrossoverHead`
        // via `adjustedContext` so user feedback (recorded after the
        // run via `recordAcceptance` / `recordRejection`) reaches the
        // same objects on subsequent optimizations.
        //
        // `FederatedMutationBandit` remains available as an opt-in
        // optimization for callers that want per-island bandits with
        // periodic merging — not wired by default because it fights
        // with the persistent-feedback path.
        let (population, convergenceGen, duration) = await Task.detached(priority: .userInitiated) {
            let startTime = Date()

            let islandGA = IslandModelGA<ScheduleChromosome>(
                islandConfig: capturedIslandConfig,
                baseConfig: config,
                context: adjustedContext,
                evaluate: surrogateAssistedEvaluator,
                multiObjective: multiObjective,
                hooks: hooks
            )

            // Cooperative cancellation: `islandGA.run()` throws
            // `CancellationError` when the enclosing Task is cancelled
            // mid-evolution. We surface whatever `bestEver` was found
            // before interruption so the UI always gets a usable
            // (if suboptimal) result.
            let pop: [ScheduleChromosome]
            do {
                pop = try islandGA.run()
            } catch is CancellationError {
                if let best = islandGA.bestEver {
                    pop = [best]
                } else {
                    pop = []
                }
            } catch {
                pop = islandGA.bestEver.map { [$0] } ?? []
            }
            let elapsed = Date().timeIntervalSince(startTime)
            return (pop, islandGA.convergenceGeneration, elapsed)
        }.value

        // Back on main thread — deposit every island individual into the
        // MAP-Elites archive and read diverse scenarios out of it.
        var archive = MAPElitesArchive()
        archive.depositAll(population, context: adjustedContext)
        let scenarios = archive.diverseScenarios(
            count: capturedScenarioCount,
            evaluator: evaluator,
            context: adjustedContext
        )

        let populationCount = population.prefix(10).count
        let metadata = OptimizationMetadata(
            generations: convergenceGen,
            totalDuration: duration,
            bestFitness: population.first?.fitness ?? 0,
            averageFitness: populationCount > 0
                ? population.prefix(10).reduce(0) { $0 + $1.fitness } / Double(populationCount)
                : 0,
            convergenceGeneration: convergenceGen
        )

        let result = OptimizerResult(scenarios: scenarios, metadata: metadata)
        lastResult = result

        if let best = scenarios.first {
            currentSchedule = best.genes
        }

        return result
    }

    // MARK: - Pareto Optimize (alias)

    /// NSGA-III is now the default survivor-selection strategy, so this
    /// method is a thin alias over `optimize`. Kept to avoid breaking
    /// callers that specifically asked for Pareto-aware scenarios.
    func optimizeWithPareto(
        context: OptimizerContext,
        overrideConfig: GAConfiguration? = nil,
        overrideIslandConfig: IslandConfiguration? = nil
    ) async -> OptimizerResult {
        await optimize(
            context: context,
            overrideConfig: overrideConfig,
            overrideIslandConfig: overrideIslandConfig
        )
    }

    // MARK: - Quick Optimize (Day)

    func optimizeToday(
        fixedEvents: [CalendarEvent],
        movableEvents: [OptimizableEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart)!

        let context = OptimizerContext(
            fixedEvents: fixedEvents.filter { $0.startDate >= todayStart && $0.startDate < todayEnd },
            movableEvents: movableEvents,
            workingHours: workingHours,
            planningHorizon: DateInterval(start: max(Date(), todayStart), end: todayEnd),
            preferences: preferences
        )

        return await optimize(context: context, overrideConfig: .quick, overrideIslandConfig: .quick)
    }

    // MARK: - Weekly Optimize

    func optimizeWeek(
        fixedEvents: [CalendarEvent],
        movableEvents: [OptimizableEvent],
        workingHours: ClosedRange<Int> = 9...18,
        participantAvailability: [String: [DateInterval]] = [:]
    ) async -> OptimizerResult {
        let now = Date()
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: now)!

        let context = OptimizerContext(
            fixedEvents: fixedEvents,
            movableEvents: movableEvents,
            workingHours: workingHours,
            planningHorizon: DateInterval(start: now, end: weekEnd),
            preferences: preferences,
            participantAvailability: participantAvailability
        )

        return await optimize(context: context)
    }

    // MARK: - Incremental Re-optimization (#26)

    func reoptimize(
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

        let result = await Task.detached(priority: .userInitiated) {
            reopt.reoptimize(
                currentSchedule: schedule,
                trigger: trigger,
                context: context,
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
    func instantReflow(context: OptimizerContext) async -> [ScheduleGene]? {
        var prefs = context.preferences
        preferenceLearner.applyToPreferences(&prefs)

        let evaluator = FitnessEvaluator.standard(preferences: prefs)
        let schedule = currentSchedule

        let result = await Task.detached(priority: .userInitiated) {
            let reopt = IncrementalReoptimizer()
            reopt.stabilityWeight = 3.0  // prefer stability for preview
            reopt.minimumImprovement = 0.01  // accept smaller improvements

            return reopt.reoptimize(
                currentSchedule: schedule,
                trigger: .periodicRefresh,
                context: context,
                evaluator: evaluator,
                config: .instant
            )
        }.value

        return result?.scenarios.first?.genes
    }

    // MARK: - User Feedback (#24)
    //
    // Feedback is fanned out to three learners:
    //   • `PreferenceLearner` — evolves per-objective weights via its
    //     meta-GA (unchanged).
    //   • `MutationBandit` — a bounded reward per operator nudges the
    //     LinUCB estimates so operators that produced accepted
    //     schedules get reinforced on subsequent runs.
    //   • `GeneAttentionHead` — a small feature-weight step biases
    //     contextual crossover toward (or away from) the patterns
    //     that led to user-visible success/failure.
    //
    // The bandit/head updates are intentionally small (~0.1 magnitude)
    // so a single decision doesn't dominate learned state; many pieces
    // of feedback converge meaningfully while one noisy accept
    // doesn't derail the model.

    func acceptScenario(_ scenario: ScheduleScenario) {
        currentSchedule = scenario.genes
        preferenceLearner.recordAcceptance(scenarioFitness: scenario.fitness)
        propagateFeedbackReward(+0.1, scenario: scenario)
    }

    func rejectScenario(_ scenario: ScheduleScenario) {
        preferenceLearner.recordRejection(scenarioFitness: scenario.fitness)
        propagateFeedbackReward(-0.1, scenario: scenario)
    }

    func recordManualEdit(original: [ScheduleGene], edited: [ScheduleGene]) {
        currentSchedule = edited
        preferenceLearner.recordModification(original: original, edited: edited)
        // Modification means "close but not right" — a mild negative
        // on both bandit and head; PreferenceLearner handles the
        // objective-weight refinement separately.
        for op in MutationOperator.allCases {
            mutationBandit.record(op: op, reward: -0.03)
        }
        contextualCrossoverHead.updateWeights(
            features: [1, 1, 1, 1],
            rewardSign: -0.3
        )
    }

    /// Apply a uniform reward signal to every bandit arm and a
    /// scenario-magnitude-scaled nudge to the attention head.
    /// Uniform across operators because we don't retain per-gene
    /// lineage — LinUCB's context features already discriminate
    /// regimes, so "reinforce whatever you were doing" averages out
    /// to the useful signal over many feedback events.
    private func propagateFeedbackReward(_ reward: Double, scenario: ScheduleScenario) {
        for op in MutationOperator.allCases {
            mutationBandit.record(op: op, reward: reward)
        }
        // Head feedback: scale by scenario fitness — high-fitness
        // accepted scenarios mean the head is doing well; weak
        // scenarios that were accepted anyway carry less signal.
        let signedMagnitude = reward.signum() * max(0.3, scenario.fitness)
        contextualCrossoverHead.updateWeights(
            features: [1, 1, 1, 1],
            rewardSign: signedMagnitude
        )
    }

    // MARK: - Scenario Comparison (#27)

    func compareLastScenarios() -> [ScenarioComparison] {
        guard let result = lastResult else { return [] }
        return ScenarioComparer.compare(result.scenarios)
    }

    // MARK: - Focus Block Suggestions (#1)

    func suggestFocusBlocks(
        count: Int = 2,
        durationMinutes: Int = 120,
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        let focusEvents = (0..<count).map { i in
            OptimizableEvent(
                title: "Focus Block \(i + 1)",
                duration: TimeInterval(durationMinutes * 60),
                priority: 0.8,
                context: "focus",
                energyCost: 0.7,
                preferredHourRange: 9...12,
                isFocusBlock: true
            )
        }

        return await optimizeToday(
            fixedEvents: fixedEvents,
            movableEvents: focusEvents,
            workingHours: workingHours
        )
    }

    // MARK: - Pomodoro Optimization (#2)

    func suggestPomodoroSlot(
        config: PomodoroConfig = .classic,
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        let totalMinutes = config.workMinutes * config.rounds
            + config.breakMinutes * max(0, config.rounds - 1)
            + config.longBreakMinutes

        let pomodoroEvent = OptimizableEvent(
            title: "Pomodoro Session",
            duration: TimeInterval(totalMinutes * 60),
            priority: 0.7,
            context: "focus",
            energyCost: 0.8,
            preferredHourRange: 9...14,
            isFocusBlock: true,
            pomodoroConfig: config
        )

        return await optimizeToday(
            fixedEvents: fixedEvents,
            movableEvents: [pomodoroEvent],
            workingHours: workingHours
        )
    }

    // MARK: - Meeting Scheduling (#5, #16)

    func suggestMeetingSlot(
        title: String,
        durationMinutes: Int,
        participants: [String],
        fixedEvents: [CalendarEvent],
        participantAvailability: [String: [DateInterval]],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        let meetingEvent = OptimizableEvent(
            title: title,
            duration: TimeInterval(durationMinutes * 60),
            priority: 0.9,
            context: "meeting",
            energyCost: 0.6,
            requiredParticipants: participants
        )

        return await optimizeWeek(
            fixedEvents: fixedEvents,
            movableEvents: [meetingEvent],
            workingHours: workingHours,
            participantAvailability: participantAvailability
        )
    }

    // MARK: - Pomodoro Task Sequence Optimization

    /// Optimize the order of tasks within a Pomodoro session.
    /// Uses a dedicated permutation GA (PomodoroSequenceChromosome) that considers
    /// energy curve, context switches, deadline urgency, and cognitive load alternation.
    ///
    /// Returns tasks reordered for optimal execution within the session.
    func optimizePomodoroSequence(
        tasks: [OptimizableEvent],
        sessionStart: Date = Date(),
        weights: PomodoroSequenceEvaluator.Weights = .default
    ) async -> [OptimizableEvent] {
        guard tasks.count > 1 else { return tasks }

        let capturedTasks = tasks
        let capturedStart = sessionStart
        let capturedWeights = weights
        let capturedPrefs = preferences

        return await Task.detached(priority: .userInitiated) {
            PomodoroSequenceOptimizer.optimize(
                tasks: capturedTasks,
                sessionStart: capturedStart,
                preferences: capturedPrefs,
                config: .quick,
                weights: capturedWeights
            )
        }.value
    }

    // MARK: - Day Planning (#6)

    func planDay(
        tasks: [OptimizableEvent],
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        await optimizeToday(
            fixedEvents: fixedEvents,
            movableEvents: tasks,
            workingHours: workingHours
        )
    }

    // MARK: - Day Planning with Pomodoro Sequencing

    /// Two-phase optimization:
    /// 1. Schedule GA places tasks in optimal time slots
    /// 2. Sequence GA optimizes task execution order within each day
    ///
    /// The result includes `taskSequenceByDay` on each scenario, indicating
    /// the recommended execution order for tasks grouped on the same day.
    func planDayWithSequencing(
        tasks: [OptimizableEvent],
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18,
        sequenceWeights: PomodoroSequenceEvaluator.Weights = .default
    ) async -> OptimizerResult {
        // Phase 1: place tasks in time slots
        var result = await planDay(
            tasks: tasks,
            fixedEvents: fixedEvents,
            workingHours: workingHours
        )

        // Phase 2: optimize task order within each day per scenario
        let taskMap = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let cal = Calendar.current
        let capturedPrefs = preferences
        let capturedWeights = sequenceWeights

        // Build all sequence optimization work items across all scenarios
        struct SequenceJob: Sendable {
            let scenarioIndex: Int
            let day: Date
            let tasks: [OptimizableEvent]
            let sessionStart: Date
        }

        var jobs: [SequenceJob] = []
        var trivialSequences: [(scenarioIndex: Int, day: Date, eventIds: [String])] = []

        for (scenarioIndex, scenario) in result.scenarios.enumerated() {
            var genesByDay: [Date: [ScheduleGene]] = [:]
            for gene in scenario.genes {
                let day = cal.startOfDay(for: gene.startTime)
                genesByDay[day, default: []].append(gene)
            }

            for (day, dayGenes) in genesByDay {
                let dayTasks = dayGenes.compactMap { taskMap[$0.eventId] }
                if dayTasks.count > 1 {
                    let sessionStart = dayGenes.map(\.startTime).min() ?? day
                    jobs.append(SequenceJob(
                        scenarioIndex: scenarioIndex,
                        day: day,
                        tasks: dayTasks,
                        sessionStart: sessionStart
                    ))
                } else {
                    trivialSequences.append((scenarioIndex, day, dayGenes.map(\.eventId)))
                }
            }
        }

        // Spawn all sequence optimizations in parallel
        let parallelTasks = jobs.map { job in
            (job, Task.detached(priority: .userInitiated) {
                PomodoroSequenceOptimizer.optimize(
                    tasks: job.tasks,
                    sessionStart: job.sessionStart,
                    preferences: capturedPrefs,
                    config: .quick,
                    weights: capturedWeights
                )
            })
        }

        // Collect results
        var sequencesByScenario: [Int: [Date: [String]]] = [:]
        for (scenarioIndex, day, eventIds) in trivialSequences {
            sequencesByScenario[scenarioIndex, default: [:]][day] = eventIds
        }

        // Await all parallel tasks
        for (job, task) in parallelTasks {
            let ordered = await task.value
            sequencesByScenario[job.scenarioIndex, default: [:]][job.day] = ordered.map(\.id)
        }

        // Build enhanced scenarios
        let enhancedScenarios = result.scenarios.enumerated().map { (idx, scenario) -> ScheduleScenario in
            var enhanced = scenario
            enhanced.taskSequenceByDay = sequencesByScenario[idx]
            return enhanced
        }

        result = OptimizerResult(
            scenarios: enhancedScenarios,
            metadata: result.metadata
        )
        lastResult = result
        return result
    }

    // MARK: - Meeting Clustering

    /// Optimize meeting placement to cluster meetings together,
    /// maximizing continuous focus blocks during the rest of the day.
    func clusterMeetings(
        meetings: [OptimizableEvent],
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        // Boost clustering weight for this specific optimization
        var prefs = preferences
        prefs.meetingClusteringWeight = max(prefs.meetingClusteringWeight, 2.0)
        prefs.focusBlockWeight = max(prefs.focusBlockWeight, 1.5)

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart)!

        let context = OptimizerContext(
            fixedEvents: fixedEvents.filter { $0.startDate >= todayStart && $0.startDate < todayEnd },
            movableEvents: meetings,
            workingHours: workingHours,
            planningHorizon: DateInterval(start: max(Date(), todayStart), end: todayEnd),
            preferences: prefs
        )

        return await optimize(context: context, overrideConfig: .quick, overrideIslandConfig: .quick)
    }

    // MARK: - Week Balancing (#9)

    func balanceWeek(
        movableEvents: [OptimizableEvent],
        fixedEvents: [CalendarEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        await optimizeWeek(
            fixedEvents: fixedEvents,
            movableEvents: movableEvents,
            workingHours: workingHours
        )
    }

    // MARK: - Reset

    func reset() {
        preferenceLearner.reset()
        currentSchedule = []
        lastResult = nil
        preferences = OptimizerPreferences()
    }
}
