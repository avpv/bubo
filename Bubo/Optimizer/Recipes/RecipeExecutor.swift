import Foundation

// MARK: - Recipe Executor

/// Universal executor that translates any ScheduleRecipe into an optimizer call.
/// Does not know about specific recipes — handles them all through data.
@MainActor
struct RecipeExecutor {

    let optimizer: BuboOptimizer
    let reminderService: ReminderService

    // MARK: - Execute

    func execute(_ recipe: ScheduleRecipe, paramValues: [String: Any] = [:]) async -> RecipeResult {
        // 0. Apply user parameters
        var recipe = recipe
        recipe.applyParamValues(paramValues)

        // 1. Create synthetic events from specs
        let syntheticEvents: [OptimizableEvent]
        do {
            syntheticEvents = try resolveEventSpecs(recipe.events)
        } catch {
            return .noEventsToOptimize
        }

        // 2. Collect existing local events (if included)
        var localEvents: [OptimizableEvent] = []
        if recipe.includeExistingEvents {
            localEvents = collectLocalEvents(for: recipe.horizon)
        }

        // 3. Apply event rules to local events
        var movableEvents = applyEventRules(recipe.eventRules, to: localEvents)

        // 4. Apply day structure (translates to preferredHourRange)
        if !recipe.dayStructure.isEmpty {
            movableEvents = applyDayStructure(recipe.dayStructure, to: movableEvents)
        }

        // 5. Separate fixed events (from markFixed rule)
        let (fixedFromRules, remaining) = partitionFixed(movableEvents)
        movableEvents = remaining

        // 6. Combine synthetic + remaining local
        let allMovable = syntheticEvents + movableEvents
        guard !allMovable.isEmpty else {
            return .noEventsToOptimize
        }

        // 7. Build preferences
        var prefs = optimizer.preferences
        if recipe.weights[.useLearned] != nil {
            optimizer.preferenceLearner.applyToPreferences(&prefs)
        } else {
            optimizer.preferenceLearner.applyToPreferences(&prefs)
            applyWeightOverrides(recipe.weights, to: &prefs)
        }
        if let v = recipe.minBreakMinutes { prefs.minBreakMinutes = v }
        if let v = recipe.maxMeetingsPerDay { prefs.maxMeetingsPerDay = v }
        if let v = recipe.peakEnergyHour { prefs.peakEnergyHour = v }

        // 8. Build working hours
        let workingHours = recipe.workingHours?.closedRange
            ?? optimizerService.workingHours

        // 9. Build planning horizon
        let horizon = resolveHorizon(recipe.horizon, workingHours: workingHours)

        // 10. Collect fixed calendar events + frozen events from rules
        let calendarFixed = reminderService.allEvents.filter { !$0.isLocalEvent }
        let allFixed = calendarFixed + fixedFromRules

        // 11. Collect participant availability
        let allParticipants = allMovable.flatMap(\.requiredParticipants)
        let availability: [String: [DateInterval]] = [:]
        // TODO: Fetch real availability when CalendarService supports it

        // 12. Build context
        let context = OptimizerContext(
            fixedEvents: allFixed,
            movableEvents: allMovable,
            workingHours: workingHours,
            planningHorizon: horizon,
            preferences: prefs,
            participantAvailability: availability
        )

        // 13. Configure stability
        switch recipe.stability {
        case .full:
            optimizer.reoptimizer.stabilityWeight = 0
        case .normal:
            optimizer.reoptimizer.stabilityWeight = 2.0
        case .conservative:
            optimizer.reoptimizer.stabilityWeight = 5.0
        }

        // 14. Pre-flight: check if there's enough working time for events
        if let preflight = preflightCheck(context: context) {
            return .infeasible(reason: preflight)
        }

        // 15. Configure scenario generation
        let scenarioGen = ScenarioGenerator()
        // scenarioGen uses default values; maxScenarios/diversityThreshold
        // are passed through GAConfiguration or handled post-optimization

        // 16. Run optimizer
        let config = recipe.speed.gaConfiguration
        let result = await optimizer.optimize(context: context, overrideConfig: config)

        // 17. Filter scenarios to recipe's diversity/count preferences
        let filteredScenarios = Array(result.scenarios.prefix(recipe.maxScenarios))
        let filteredResult = OptimizerResult(
            scenarios: filteredScenarios,
            metadata: result.metadata
        )

        // 18. Check result quality
        if filteredResult.scenarios.isEmpty {
            return .infeasible(reason: "No feasible schedule found for the given constraints")
        }

        if let best = filteredResult.scenarios.first, best.fitness < 0.1 {
            return .infeasible(reason: "Cannot satisfy hard constraints with current events and time")
        }

        return .success(filteredResult)
    }

    // MARK: - Resolve Event Specs

    private func resolveEventSpecs(_ specs: [EventSpec]) throws -> [OptimizableEvent] {
        specs.flatMap { spec -> [OptimizableEvent] in
            switch spec.creation {
            case .fixed:
                return createFixedEvents(from: spec)

            case .fillGaps:
                let gaps = findFreeGaps()
                return gaps
                    .filter { $0.duration >= 1800 } // at least 30 min
                    .map { gap in
                        OptimizableEvent(
                            title: spec.title,
                            duration: gap.duration,
                            priority: spec.priority,
                            context: spec.context,
                            energyCost: spec.energy,
                            preferredHourRange: spec.period?.hourRange,
                            isFocusBlock: spec.focus,
                            pomodoroConfig: spec.pomodoro?.config
                        )
                    }

            case .fromUnfinished:
                return collectUnfinishedEvents()

            case .splitEvent(let eventId):
                guard let original = findLocalEvent(eventId) else { return [] }
                let partMinutes = max(15, Int(original.duration / 60) / max(1, spec.count))
                return (0..<spec.count).map { i in
                    OptimizableEvent(
                        title: "\(original.title) (\(i + 1)/\(spec.count))",
                        duration: TimeInterval(partMinutes * 60),
                        priority: spec.priority,
                        context: original.title,
                        energyCost: spec.energy,
                        isFocusBlock: spec.focus
                    )
                }
            }
        }
    }

    private func createFixedEvents(from spec: EventSpec) -> [OptimizableEvent] {
        (0..<spec.count).map { i in
            OptimizableEvent(
                title: spec.count > 1 ? "\(spec.title) \(i + 1)" : spec.title,
                duration: TimeInterval(spec.minutes * 60),
                priority: spec.priority,
                context: spec.context,
                energyCost: spec.energy,
                requiredParticipants: spec.participants,
                preferredHourRange: spec.period?.hourRange,
                isFocusBlock: spec.focus,
                pomodoroConfig: spec.pomodoro?.config
            )
        }
    }

    // MARK: - Apply Event Rules

    private func applyEventRules(_ rules: [EventRule], to events: [OptimizableEvent]) -> [OptimizableEvent] {
        var result = events
        for rule in rules {
            result = result.compactMap { event in
                guard matches(event, rule.match) else { return event }
                return apply(rule.action, to: event)
            }
        }
        return result
    }

    private func matches(_ event: OptimizableEvent, _ match: EventMatch) -> Bool {
        switch match {
        case .all:
            return true
        case .context(let ctx):
            return event.context == ctx
        case .focusBlocks:
            return event.isFocusBlock
        case .meetings:
            return !event.requiredParticipants.isEmpty || event.context == "meeting"
        case .highEnergy:
            return event.energyCost > 0.6
        case .lowEnergy:
            return event.energyCost <= 0.3
        case .withDeadline:
            return event.deadline != nil
        case .longerThan(let minutes):
            return event.duration > TimeInterval(minutes * 60)
        case .id(let id):
            return event.id == id
        case .ids(let ids):
            return ids.contains(event.id)
        case .onDay, .onDays:
            // Day matching applies during optimization via restrictToDays action,
            // not during pre-filtering
            return false
        }
    }

    /// Returns nil to exclude the event, or a modified event.
    private func apply(_ action: EventAction, to event: OptimizableEvent) -> OptimizableEvent? {
        switch action {
        case .setPriority(let p):
            return OptimizableEvent(
                id: event.id, title: event.title, duration: event.duration,
                deadline: event.deadline, priority: p,
                context: event.context, energyCost: event.energyCost,
                requiredParticipants: event.requiredParticipants,
                preferredHourRange: event.preferredHourRange,
                isFocusBlock: event.isFocusBlock, pomodoroConfig: event.pomodoroConfig
            )
        case .setPreferredPeriod(let period):
            return OptimizableEvent(
                id: event.id, title: event.title, duration: event.duration,
                deadline: event.deadline, priority: event.priority,
                context: event.context, energyCost: event.energyCost,
                requiredParticipants: event.requiredParticipants,
                preferredHourRange: period.hourRange,
                isFocusBlock: event.isFocusBlock, pomodoroConfig: event.pomodoroConfig
            )
        case .markFixed:
            // Handled separately in partitionFixed
            return event
        case .exclude:
            return nil
        case .setEnergy(let e):
            return OptimizableEvent(
                id: event.id, title: event.title, duration: event.duration,
                deadline: event.deadline, priority: event.priority,
                context: event.context, energyCost: e,
                requiredParticipants: event.requiredParticipants,
                preferredHourRange: event.preferredHourRange,
                isFocusBlock: event.isFocusBlock, pomodoroConfig: event.pomodoroConfig
            )
        case .restrictToDays:
            // Day restriction is enforced by adding preferredHourRange constraints
            // during optimization. For now, keep the event as-is.
            // TODO: Implement day restriction via custom constraint or event metadata
            return event
        }
    }

    // MARK: - Day Structure

    private func applyDayStructure(_ structure: [TimeBlock], to events: [OptimizableEvent]) -> [OptimizableEvent] {
        events.map { event in
            // Determine event's block type
            let blockType: BlockType
            if event.isFocusBlock {
                blockType = .focus
            } else if !event.requiredParticipants.isEmpty || event.context == "meeting" {
                blockType = .meetings
            } else {
                blockType = .tasks
            }

            // Find which periods allow this block type
            let allowedPeriods = structure.filter { $0.allowedTypes.contains(blockType) }.map(\.period)

            // If there's a single allowed period, set it as preferred
            if let preferred = allowedPeriods.first, allowedPeriods.count == 1 {
                return OptimizableEvent(
                    id: event.id, title: event.title, duration: event.duration,
                    deadline: event.deadline, priority: event.priority,
                    context: event.context, energyCost: event.energyCost,
                    requiredParticipants: event.requiredParticipants,
                    preferredHourRange: preferred.hourRange,
                    isFocusBlock: event.isFocusBlock, pomodoroConfig: event.pomodoroConfig
                )
            }

            return event
        }
    }

    // MARK: - Partition Fixed

    private func partitionFixed(_ events: [OptimizableEvent]) -> (fixed: [CalendarEvent], movable: [OptimizableEvent]) {
        // Events marked as fixed by rules stay in their current position
        // For now, all events are movable since markFixed needs current position info
        return ([], events)
    }

    // MARK: - Weight Overrides

    private func applyWeightOverrides(_ weights: [WeightKey: Double], to prefs: inout OptimizerPreferences) {
        for (key, value) in weights {
            switch key {
            case .focusBlock:     prefs.focusBlockWeight = value
            case .pomodoroFit:    prefs.pomodoroFitWeight = value
            case .conflict:      prefs.conflictWeight = value
            case .taskPlacement: prefs.taskPlacementWeight = value
            case .weekBalance:   prefs.weekBalanceWeight = value
            case .energyCurve:   prefs.energyCurveWeight = value
            case .multiPerson:   prefs.multiPersonWeight = value
            case .breakPlacement: prefs.breakWeight = value
            case .deadline:      prefs.deadlineWeight = value
            case .contextSwitch: prefs.contextSwitchWeight = value
            case .buffer:        prefs.bufferWeight = value
            case .useLearned:    break // handled separately
            }
        }
    }

    // MARK: - Pre-flight Validation

    /// Returns a user-facing error message if the schedule is clearly infeasible,
    /// or nil if the optimizer should proceed.
    private func preflightCheck(context: OptimizerContext) -> String? {
        let cal = context.calendar
        let now = Date()

        // Calculate total available working minutes within the planning horizon
        var availableMinutes: Double = 0
        var day = cal.startOfDay(for: context.planningHorizon.start)
        let horizonEnd = context.planningHorizon.end

        while day < horizonEnd {
            guard let workStart = cal.date(
                bySettingHour: context.workingHours.lowerBound, minute: 0, second: 0, of: day
            ), let workEnd = cal.date(
                bySettingHour: context.workingHours.upperBound, minute: 0, second: 0, of: day
            ) else {
                day = cal.date(byAdding: .day, value: 1, to: day)!
                continue
            }

            // Clamp to planning horizon and current time
            let effectiveStart = max(workStart, max(now, context.planningHorizon.start))
            let effectiveEnd = min(workEnd, horizonEnd)

            if effectiveEnd > effectiveStart {
                var freeMinutes = effectiveEnd.timeIntervalSince(effectiveStart) / 60

                // Subtract fixed events that overlap this working window
                for fixed in context.fixedEvents {
                    let overlapStart = max(fixed.startDate, effectiveStart)
                    let overlapEnd = min(fixed.endDate, effectiveEnd)
                    if overlapEnd > overlapStart {
                        freeMinutes -= overlapEnd.timeIntervalSince(overlapStart) / 60
                    }
                }

                availableMinutes += max(0, freeMinutes)
            }

            day = cal.date(byAdding: .day, value: 1, to: day)!
        }

        // Calculate total required minutes
        let requiredMinutes = context.movableEvents.reduce(0.0) { $0 + $1.duration / 60 }

        if availableMinutes < 1 {
            return "No working time left today — try scheduling for tomorrow"
        }

        if requiredMinutes > availableMinutes {
            let needed = Int(requiredMinutes)
            let available = Int(availableMinutes)
            return "Need \(needed) min but only \(available) min of working time available"
        }

        return nil
    }

    // MARK: - Horizon Resolution

    private func resolveHorizon(_ horizon: Horizon, workingHours: ClosedRange<Int>) -> DateInterval {
        let cal = Calendar.current
        let now = Date()

        switch horizon {
        case .today:
            let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!

            // Check remaining working hours today
            let workEndToday = cal.date(
                bySettingHour: workingHours.upperBound, minute: 0, second: 0, of: now
            ) ?? todayEnd
            let remainingMinutes = workEndToday.timeIntervalSince(now) / 60

            // If less than 30 minutes of working time remain, extend to end of tomorrow
            // so the optimizer can place events on the next day
            if remainingMinutes < 30 {
                let tomorrowEnd = cal.date(byAdding: .day, value: 1, to: todayEnd)!
                return DateInterval(start: now, end: tomorrowEnd)
            }

            return DateInterval(start: now, end: todayEnd)

        case .tomorrow:
            let tomorrowStart = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            let tomorrowEnd = cal.date(byAdding: .day, value: 1, to: tomorrowStart)!
            return DateInterval(start: tomorrowStart, end: tomorrowEnd)

        case .week:
            let weekEnd = cal.date(byAdding: .day, value: 7, to: now)!
            return DateInterval(start: now, end: weekEnd)
        }
    }

    // MARK: - Event Collection

    private func collectLocalEvents(for horizon: Horizon) -> [OptimizableEvent] {
        let cal = Calendar.current
        let now = Date()

        let localEvents = reminderService.localEvents.filter { $0.isUpcoming }

        switch horizon {
        case .today:
            let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            return localEvents
                .filter { $0.startDate >= now && $0.startDate < todayEnd }
                .map { $0.toOptimizableEvent() }

        case .tomorrow:
            let tomorrowStart = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            let tomorrowEnd = cal.date(byAdding: .day, value: 1, to: tomorrowStart)!
            return localEvents
                .filter { $0.startDate >= tomorrowStart && $0.startDate < tomorrowEnd }
                .map { $0.toOptimizableEvent() }

        case .week:
            let weekEnd = cal.date(byAdding: .day, value: 7, to: now)!
            return localEvents
                .filter { $0.startDate >= now && $0.startDate < weekEnd }
                .map { $0.toOptimizableEvent() }
        }
    }

    private func findFreeGaps() -> [DateInterval] {
        let cal = Calendar.current
        let now = Date()
        let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let allEvents = reminderService.allEvents
            .filter { $0.startDate >= now && $0.startDate < todayEnd }
            .sorted { $0.startDate < $1.startDate }

        var gaps: [DateInterval] = []
        var cursor = now

        for event in allEvents {
            if event.startDate > cursor {
                gaps.append(DateInterval(start: cursor, end: event.startDate))
            }
            cursor = max(cursor, event.endDate)
        }

        if cursor < todayEnd {
            gaps.append(DateInterval(start: cursor, end: todayEnd))
        }

        return gaps
    }

    private func collectUnfinishedEvents() -> [OptimizableEvent] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        return reminderService.localEvents
            .filter { $0.endDate < todayStart && $0.isLocalEvent }
            .map { $0.toOptimizableEvent() }
    }

    private func findLocalEvent(_ id: String) -> CalendarEvent? {
        reminderService.localEvents.first { $0.id == id }
    }

    // MARK: - Accessor for OptimizerService working hours

    private var optimizerService: OptimizerService {
        // The executor is created with optimizer and reminderService,
        // working hours come from the optimizer's preferences.
        // This is a convenience to avoid passing another dependency.
        // In practice, the caller (OptimizerService) passes working hours.
        fatalError("Use execute() through OptimizerService which provides working hours")
    }
}

// MARK: - RecipeExecutor with Working Hours

extension RecipeExecutor {

    /// Execute with explicit working hours (called from OptimizerService).
    func execute(
        _ recipe: ScheduleRecipe,
        paramValues: [String: Any] = [:],
        defaultWorkingHours: ClosedRange<Int>
    ) async -> RecipeResult {
        var recipe = recipe
        recipe.applyParamValues(paramValues)

        let syntheticEvents: [OptimizableEvent]
        do {
            syntheticEvents = try resolveEventSpecs(recipe.events)
        } catch {
            return .noEventsToOptimize
        }

        var localEvents: [OptimizableEvent] = []
        if recipe.includeExistingEvents {
            localEvents = collectLocalEvents(for: recipe.horizon)

            // Filter to user-selected events when specified
            if let selected = recipe.selectedEventIds {
                let selectedSet = Set(selected)
                localEvents = localEvents.filter { selectedSet.contains($0.id) }
            }
        }

        var movableEvents = applyEventRules(recipe.eventRules, to: localEvents)

        if !recipe.dayStructure.isEmpty {
            movableEvents = applyDayStructure(recipe.dayStructure, to: movableEvents)
        }

        let (fixedFromRules, remaining) = partitionFixed(movableEvents)
        movableEvents = remaining

        let allMovable = syntheticEvents + movableEvents
        guard !allMovable.isEmpty else {
            return .noEventsToOptimize
        }

        var prefs = optimizer.preferences
        if recipe.weights[.useLearned] != nil {
            optimizer.preferenceLearner.applyToPreferences(&prefs)
        } else {
            optimizer.preferenceLearner.applyToPreferences(&prefs)
            applyWeightOverrides(recipe.weights, to: &prefs)
        }
        if let v = recipe.minBreakMinutes { prefs.minBreakMinutes = v }
        if let v = recipe.maxMeetingsPerDay { prefs.maxMeetingsPerDay = v }
        if let v = recipe.peakEnergyHour { prefs.peakEnergyHour = v }

        let workingHours = recipe.workingHours?.closedRange ?? defaultWorkingHours
        let horizon = resolveHorizon(recipe.horizon, workingHours: workingHours)

        let calendarFixed = reminderService.allEvents.filter { !$0.isLocalEvent }
        let allFixed = calendarFixed + fixedFromRules

        let context = OptimizerContext(
            fixedEvents: allFixed,
            movableEvents: allMovable,
            workingHours: workingHours,
            planningHorizon: horizon,
            preferences: prefs
        )

        switch recipe.stability {
        case .full:
            optimizer.reoptimizer.stabilityWeight = 0
        case .normal:
            optimizer.reoptimizer.stabilityWeight = 2.0
        case .conservative:
            optimizer.reoptimizer.stabilityWeight = 5.0
        }

        // Pre-flight: check if there's enough working time for events
        if let preflight = preflightCheck(context: context) {
            return .infeasible(reason: preflight)
        }

        let config = recipe.speed.gaConfiguration

        // Separate chained events: only chain heads go to GA
        let chainInfo = buildChainInfo(recipe.events, allMovable: allMovable)
        let gaMovable: [OptimizableEvent]
        if chainInfo.hasChains {
            gaMovable = chainInfo.headEvents + movableEvents
        } else {
            gaMovable = allMovable
        }

        // Re-build context with only GA-optimizable events
        let gaContext = chainInfo.hasChains
            ? OptimizerContext(
                fixedEvents: allFixed,
                movableEvents: gaMovable,
                workingHours: workingHours,
                planningHorizon: horizon,
                preferences: prefs
            )
            : context

        let result = await optimizer.optimize(context: gaContext, overrideConfig: config)

        // Post-process: insert chained events into scenarios
        let processedScenarios: [ScheduleScenario]
        if chainInfo.hasChains {
            processedScenarios = result.scenarios.map { scenario in
                let expandedGenes = expandChains(scenario.genes, chainInfo: chainInfo)
                return ScheduleScenario(
                    genes: expandedGenes,
                    fitness: scenario.fitness,
                    objectiveBreakdown: scenario.objectiveBreakdown,
                    constraintViolations: scenario.constraintViolations
                )
            }
        } else {
            processedScenarios = result.scenarios
        }

        let filteredScenarios = Array(processedScenarios.prefix(recipe.maxScenarios))
        let filteredResult = OptimizerResult(
            scenarios: filteredScenarios,
            metadata: result.metadata
        )

        if filteredResult.scenarios.isEmpty {
            return .infeasible(reason: "No feasible schedule found for the given constraints")
        }

        if let best = filteredResult.scenarios.first, best.fitness < 0.1 {
            return .infeasible(reason: "Cannot satisfy hard constraints with current events and time")
        }

        return .success(filteredResult)
    }

    // MARK: - Chain Processing

    /// Info about event chains for post-processing after GA.
    struct ChainInfo {
        /// Whether any chains exist in the recipe.
        var hasChains: Bool
        /// Events that go to the GA (chain heads + independent).
        var headEvents: [OptimizableEvent]
        /// Ordered chain followers grouped by head event ID.
        /// Key = head event ID, Value = [(follower event, gap minutes)]
        var chains: [String: [(event: OptimizableEvent, gapMinutes: Int)]]
    }

    /// Analyze event specs and separate chain heads from followers.
    private func buildChainInfo(_ specs: [EventSpec], allMovable: [OptimizableEvent]) -> ChainInfo {
        var hasChains = false
        var headEvents: [OptimizableEvent] = []
        var chains: [String: [(event: OptimizableEvent, gapMinutes: Int)]] = [:]
        var currentHeadId: String? = nil
        var eventIndex = 0

        for spec in specs {
            let eventsForSpec = resolveSpecToEvents(spec)
            for event in eventsForSpec {
                if spec.chainGap != nil, let headId = currentHeadId {
                    // This is a chain follower
                    hasChains = true
                    chains[headId, default: []].append((event: event, gapMinutes: spec.chainGap ?? 0))
                } else {
                    // This is a chain head or independent event
                    currentHeadId = event.id
                    headEvents.append(event)
                }
                eventIndex += 1
            }
        }

        return ChainInfo(hasChains: hasChains, headEvents: headEvents, chains: chains)
    }

    /// Resolve a single EventSpec to OptimizableEvents (without chain logic).
    private func resolveSpecToEvents(_ spec: EventSpec) -> [OptimizableEvent] {
        switch spec.creation {
        case .fixed:
            return createFixedEvents(from: spec)
        default:
            // For non-fixed creation modes, chains don't apply
            return createFixedEvents(from: spec)
        }
    }

    /// After GA optimization, expand chain heads into full chains
    /// by placing followers sequentially.
    private func expandChains(_ genes: [ScheduleGene], chainInfo: ChainInfo) -> [ScheduleGene] {
        var result: [ScheduleGene] = []

        for gene in genes {
            result.append(gene)

            // If this gene is a chain head, append its followers
            if let followers = chainInfo.chains[gene.eventId] {
                var cursor = gene.endTime

                for (followerEvent, gapMinutes) in followers {
                    let gapInterval = TimeInterval(gapMinutes * 60)
                    let followerStart = cursor.addingTimeInterval(gapInterval)

                    let followerGene = ScheduleGene(
                        eventId: followerEvent.id,
                        title: followerEvent.title,
                        startTime: followerStart,
                        duration: followerEvent.duration,
                        context: followerEvent.context,
                        energyCost: followerEvent.energyCost,
                        priority: followerEvent.priority,
                        isFocusBlock: followerEvent.isFocusBlock
                    )

                    result.append(followerGene)
                    cursor = followerGene.endTime
                }
            }
        }

        return result
    }
}
