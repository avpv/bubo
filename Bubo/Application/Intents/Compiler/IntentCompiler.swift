import Foundation
import os
import BuboDomain
import BuboOptimizer

let intentCompilerLogger = Logger(subsystem: "com.avpv.Bubo", category: "Optimizer/Intents")
let intentsOSLog = OSLog(subsystem: "com.avpv.Bubo", category: "Optimizer/Intents")

// MARK: - Intent Compiler

/// Compiles an OptimizationRequest into an OptimizerContext and runs the GA.
///
/// Full pipeline:
/// 1. Expand subgraphs and apply variables
/// 2. Build DAG from expanded intents (auto-resolve deps)
/// 3. Validate ports (type-check connections)
/// 4. Topologically sort by phase (trigger → source → ... → output)
/// 5. Evaluate conditions at runtime
/// 6. Apply transforms to events
/// 7. Compile into OptimizerContext → run GA
/// 8. Process output nodes (autoApply, chain, notify)
@MainActor
struct IntentCompiler {

    let optimizer: BuboOptimizer
    let reminderService: ReminderService
    let backlogService: BacklogService
    var subgraphRegistry: SubgraphRegistry?
    var energyCheckInService: EnergyCheckInService?
    /// Closes the learning loop for `PomodoroConfigResolver`. When present,
    /// resolved session shapes blend with the median of recent completed
    /// sessions at a similar time of day.
    var pomodoroHistory: PomodoroHistoryService?

    // MARK: - Execute

    func execute(
        _ request: OptimizationRequest,
        defaultWorkingHours: ClosedRange<Int>
    ) async -> OptimizationResult {
        // Short per-call correlation id so every log line tied to this
        // optimization can be grep'd out of the stream together. UUIDs
        // would be noise — an 8-char hex is enough for a single day of
        // logs on one device.
        let requestId = String(format: "%08x", UInt32.random(in: .min ... .max))
        let startedAt = Date()
        // `cases` join + user-named preset both deferred via OSLog
        // interpolation. Preset name is `.private` — user-authored
        // content — while the structural `cases` enum list stays
        // `.public` since it carries no user data.
        intentCompilerLogger.info("intents_received rid=\(requestId, privacy: .public) name=\(request.name ?? "", privacy: .public) count=\(request.intents.count) cases=\(request.intents.map(\.caseName).joined(separator: ","), privacy: .public)")

        // Phase 0: Expand subgraphs and apply variables
        var expandedIntents = request.intents
        if let registry = subgraphRegistry {
            // Cache miss is fine here — subgraph expansion mutates the
            // graph after build, so caching the *expanded* graph isn't
            // sound. The cached entry corresponds to the pre-expansion
            // structure; we discard it deliberately.
            var graph = IntentGraphSalsaCache.shared.graph(for: expandedIntents)
            graph.expandSubgraphs(subgraphs: registry.subgraphs, variables: request.variables)
            expandedIntents = graph.sortedIntents()
            if expandedIntents.count != request.intents.count {
                intentCompilerLogger.info("intents_subgraph_expanded rid=\(requestId, privacy: .public) before=\(request.intents.count) after=\(expandedIntents.count)")
            }
        }

        // Phase 1: Build graph, resolve dependencies, sort topologically.
        // The shared cache survives across `execute()` calls so rapid
        // chip edits in the UI hit a warm graph instead of rebuilding
        // auto-resolution + topological sort every keystroke.
        let graph = IntentGraphSalsaCache.shared.graph(for: expandedIntents)
        let orderedIntents = graph.sortedIntents()

        var config = ResolvedConfig(defaultWorkingHours: defaultWorkingHours)

        for intent in orderedIntents {
            apply(intent, to: &config, requestId: requestId)
        }

        // Phase 1.5: Resolve any `.auto` pomodoro specs now that the full
        // intent context is known (peak energy, backlog state, working hours).
        resolveAutoPomodoros(in: &config)

        // Phase 2: Collect events (filtered by sources)
        let syntheticEvents = resolveSyntheticEvents(config)
        var localEvents = collectLocalEvents(config)
        localEvents = applyEventRules(config, to: localEvents)

        // Phase 2.5: Apply transforms
        var allMovable = syntheticEvents + localEvents
        allMovable = applyTransforms(config.transforms, to: allMovable)

        // Phase 3: Build optimizer context
        let prefs = buildPreferences(config)
        let workingHours = config.workingHours
        let maxEventMinutes = allMovable.map { $0.duration / 60 }.max() ?? 30
        // Use the larger of (longest event) and (total non-droppable time) so the
        // horizon overflows to the next day when required tasks can't all fit today.
        let totalRequiredMinutes = allMovable.filter { !$0.isDroppable }.reduce(0.0) { $0 + $1.duration / 60 }
        let minRequiredMinutes = max(maxEventMinutes, totalRequiredMinutes)
        let horizon = resolveHorizon(
            config.horizon,
            workingHours: workingHours,
            minRequiredMinutes: minRequiredMinutes,
            overflowToNextDay: config.overflowToTomorrow
        )

        let calendarFixed = reminderService.allEvents.filter { !$0.isLocalEvent }
        let localAsFixed: [CalendarEvent] = config.findSlotsOnly
            ? reminderService.allEvents.filter { $0.isLocalEvent }
            : []
        var allFixed = calendarFixed + localAsFixed

        // Tasks that an `autoPomodoro` spec reserved (see
        // `resolveAutoPomodoros`) may still be present in
        // `reminderService.allEvents` from a previous scheduling run. Drop
        // those copies so the synthetic pomodoro is the sole event carrying
        // that id — otherwise `ScheduleConflictGraph` would see fixed
        // +movable duplicates and crash its union-find build.
        let reservedPomodoroIds = Set(
            config.syntheticEvents.compactMap { $0.autoPomodoro ? $0.specId : nil }
        )
        if !reservedPomodoroIds.isEmpty {
            allFixed = allFixed.filter { !reservedPomodoroIds.contains($0.id) }
        }

        // Phase 3.5: Add backlog tasks (capped to available time)
        // The cap is generous (120%) because the GA can drop droppable tasks
        // that don't fit via the isIncluded gene mechanism.
        let totalBacklogCount: Int
        if config.includeBacklog {
            var backlogTasks = collectBacklogTasks(config)
            backlogTasks = applyTransforms(config.transforms, to: backlogTasks)
            backlogTasks = Self.splitOversizedBacklogTasks(backlogTasks, workingHours: workingHours)
            totalBacklogCount = backlogTasks.count

            // When rescheduling, remove old calendar events for these tasks
            // from both the fixed and movable sets so the backlog task itself
            // drives placement. Without this, a backlog task that was already
            // scheduled in a previous run appears twice in `allMovable` —
            // once as its local calendar event (same id as the task) and
            // once via `collectBacklogTasks` — and `ScheduleConflictGraph`
            // crashes with "Duplicate values for key" when building its
            // union-find map.
            let rescheduledIds = Set(backlogTasks.map { $0.id })
            allFixed = allFixed.filter { !rescheduledIds.contains($0.id) }
            allMovable = allMovable.filter { !rescheduledIds.contains($0.id) }

            let capped = capBacklogToAvailableTime(
                backlogTasks,
                coreEvents: allMovable,
                fixedEvents: allFixed,
                workingHours: workingHours,
                horizon: horizon,
                maxExtraTasks: config.maxExtraTasks
            )
            allMovable += capped
        } else {
            totalBacklogCount = 0
        }

        guard !allMovable.isEmpty else {
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            intentCompilerLogger.info("optimization_completed rid=\(requestId, privacy: .public) result=no_events duration_ms=\(durationMs)")
            return .noEventsToOptimize
        }

        // Pre-build the conflict graph through the shared cache so the
        // holder we hand to `OptimizerContext` is already warm. Two
        // back-to-back optimizations with the same movable-event set
        // (e.g. weight tuning, what-if scenarios) skip the build
        // entirely — the cache returns the prior instance and the
        // holder's double-checked store hands it out to every
        // chromosome on the hot path.
        let cachedConflictGraph = optimizer.conflictGraphCache.graph(forMovableEvents: allMovable, rid: requestId)
        let context = OptimizerContext(
            fixedEvents: allFixed,
            movableEvents: allMovable,
            workingHours: workingHours,
            planningHorizon: horizon,
            preferences: prefs,
            conflictGraphHolder: ConflictGraphHolder(preloaded: cachedConflictGraph)
        )

        // Phase 4: Configure stability
        switch config.stability {
        case .full:
            optimizer.reoptimizer.stabilityWeight = 0
        case .normal:
            optimizer.reoptimizer.stabilityWeight = 2.0
        case .conservative:
            optimizer.reoptimizer.stabilityWeight = 5.0
        }

        // Phase 5: Pre-flight check (only for non-droppable events)
        let snapshot = buildSnapshot(fixedEvents: allFixed, workingHours: workingHours, horizon: horizon)
        let hasDroppable = allMovable.contains { $0.isDroppable }
        if !hasDroppable, let failure = preflightCheck(context: context) {
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            intentCompilerLogger.warning("optimization_completed rid=\(requestId, privacy: .public) result=infeasible stage=preflight reason=\(failure.reason, privacy: .private) duration_ms=\(durationMs)")
            return .infeasible(reason: failure.reason, snapshot: snapshot, resolutions: failure.resolutions)
        }

        // Phase 6: Run GA
        let gaConfig = config.speed.gaConfiguration
        let result = await optimizer.optimize(context: context, overrideConfig: gaConfig, rid: requestId)

        let maxScenarios = config.maxScenarios
        let filteredScenarios = Array(result.scenarios.prefix(maxScenarios))
        let filteredResult = OptimizerResult(
            scenarios: filteredScenarios,
            metadata: result.metadata
        )

        let capacityResolutions = buildCapacityResolutions(config)

        if filteredResult.scenarios.isEmpty {
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            intentCompilerLogger.warning("optimization_completed rid=\(requestId, privacy: .public) result=infeasible stage=ga reason=no_scenarios duration_ms=\(durationMs)")
            return .infeasible(reason: "Could not find a valid placement", snapshot: snapshot, resolutions: capacityResolutions)
        }

        if let best = filteredResult.scenarios.first, best.fitness < 0.1 {
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            intentCompilerLogger.warning("optimization_completed rid=\(requestId, privacy: .public) result=infeasible stage=ga reason=low_fitness fitness=\(best.fitness) duration_ms=\(durationMs)")
            return .infeasible(reason: "Not enough room in this time window", snapshot: snapshot, resolutions: capacityResolutions)
        }

        // Phase 7: Detect dropped tasks and report partial success
        if let best = filteredResult.scenarios.first, best.droppedCount > 0 {
            let planned = best.activeGenes.count
            let total = planned + best.droppedCount
            let precapped = totalBacklogCount
            var warnings: [String] = []
            if precapped > total {
                warnings.append("Planned \(planned)\u{00A0}of\u{00A0}\(precapped)\u{00A0}tasks")
            } else {
                warnings.append("Planned \(planned)\u{00A0}of\u{00A0}\(total)\u{00A0}tasks")
            }

            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            intentCompilerLogger.info("optimization_completed rid=\(requestId, privacy: .public) result=partial_success scenarios=\(filteredResult.scenarios.count) planned=\(planned) dropped=\(best.droppedCount) duration_ms=\(durationMs)")
            return .partialSuccess(filteredResult, warnings: warnings, resolutions: capacityResolutions)
        }

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let planned = filteredResult.scenarios.first?.activeGenes.count ?? 0
        intentCompilerLogger.info("optimization_completed rid=\(requestId, privacy: .public) result=success scenarios=\(filteredResult.scenarios.count) planned=\(planned) duration_ms=\(durationMs)")
        return .success(filteredResult)
    }

    /// Suggestions offered when the horizon is too tight: extend the day,
    /// allow overflow, or push to tomorrow.
    private func buildCapacityResolutions(_ config: ResolvedConfig) -> [ActionableResolution] {
        var resolutions: [ActionableResolution] = []
        let currentEnd = config.workingHours.upperBound
        if currentEnd < 23 {
            resolutions.append(ActionableResolution(
                title: "Extend day to \(min(24, currentEnd + 2)):00",
                modifier: OptimizationRequest(.workingHours(start: config.workingHours.lowerBound, end: min(24, currentEnd + 2)))
            ))
        }
        if config.horizon == .today && !config.overflowToTomorrow {
            resolutions.append(ActionableResolution(
                title: "Allow overflow to tomorrow",
                modifier: OptimizationRequest(.overflowToTomorrow)
            ))
            resolutions.append(ActionableResolution(
                title: "Schedule tomorrow instead",
                modifier: OptimizationRequest(.horizon(.tomorrow))
            ))
        }
        return resolutions
    }
}




