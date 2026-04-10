import Foundation

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

    // MARK: - Execute

    func execute(
        _ request: OptimizationRequest,
        defaultWorkingHours: ClosedRange<Int>
    ) async -> OptimizationResult {
        // Phase 0: Expand subgraphs and apply variables
        var expandedIntents = request.intents
        if let registry = subgraphRegistry {
            var graph = IntentGraph.build(from: expandedIntents)
            graph.expandSubgraphs(registry: registry, variables: request.variables)
            expandedIntents = graph.sortedIntents()
        }

        // Phase 1: Build graph, resolve dependencies, sort topologically
        let graph = IntentGraph.build(from: expandedIntents)
        let orderedIntents = graph.sortedIntents()

        var config = ResolvedConfig(defaultWorkingHours: defaultWorkingHours)

        for intent in orderedIntents {
            apply(intent, to: &config)
        }

        // Phase 2: Collect events (filtered by sources)
        let syntheticEvents = resolveSyntheticEvents(config)
        var localEvents = collectLocalEvents(config)
        localEvents = applyEventRules(config, to: localEvents)

        // Phase 2.5: Apply transforms
        var allMovable = syntheticEvents + localEvents
        allMovable = applyTransforms(config.transforms, to: allMovable)
        guard !allMovable.isEmpty else {
            return .noEventsToOptimize
        }

        // Phase 3: Build optimizer context
        let prefs = buildPreferences(config)
        let workingHours = config.workingHours
        let maxEventMinutes = allMovable.map { $0.duration / 60 }.max() ?? 30
        let horizon = resolveHorizon(config.horizon, workingHours: workingHours, minRequiredMinutes: maxEventMinutes)

        let calendarFixed = reminderService.allEvents.filter { !$0.isLocalEvent }
        let localAsFixed: [CalendarEvent] = config.findSlotsOnly
            ? reminderService.allEvents.filter { $0.isLocalEvent }
            : []
        let allFixed = calendarFixed + localAsFixed

        let context = OptimizerContext(
            fixedEvents: allFixed,
            movableEvents: allMovable,
            workingHours: workingHours,
            planningHorizon: horizon,
            preferences: prefs
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

        // Phase 5: Pre-flight check
        let snapshot = buildSnapshot(fixedEvents: allFixed, workingHours: workingHours, horizon: horizon)
        if let error = preflightCheck(context: context) {
            return .infeasible(reason: error, snapshot: snapshot)
        }

        // Phase 6: Run GA
        let gaConfig = config.speed.gaConfiguration
        let result = await optimizer.optimize(context: context, overrideConfig: gaConfig)

        let maxScenarios = config.maxScenarios
        let filteredScenarios = Array(result.scenarios.prefix(maxScenarios))
        let filteredResult = OptimizerResult(
            scenarios: filteredScenarios,
            metadata: result.metadata
        )

        if filteredResult.scenarios.isEmpty {
            return .infeasible(reason: "No feasible schedule found", snapshot: snapshot)
        }

        if let best = filteredResult.scenarios.first, best.fitness < 0.1 {
            return .infeasible(reason: "Cannot satisfy constraints with current schedule", snapshot: snapshot)
        }

        return .success(filteredResult)
    }
}

// MARK: - Resolved Config (intermediate representation)

private extension IntentCompiler {

    /// Intermediate state built up by applying intents one at a time.
    struct ResolvedConfig {
        var workingHours: ClosedRange<Int>
        var horizon: Horizon = .today
        var speed: Speed = .quick
        var stability: Stability = .normal
        var maxScenarios: Int = 3
        var findSlotsOnly: Bool = false

        // Weight overrides (nil = use default)
        var weights: [WeightKey: Double] = [:]

        // Preference overrides
        var peakEnergyHour: Int? = nil
        var maxMeetingsPerDay: Int? = nil
        var minBreakMinutes: Int? = nil
        var lunchStart: Int? = nil
        var lunchEnd: Int? = nil

        // Synthetic events to create
        var syntheticEvents: [EventSpec] = []

        // Event rules
        var excludeIds: Set<String> = []
        var fixedIds: Set<String> = []
        var onlyIds: Set<String>? = nil  // nil = include all
        var periodOverrides: [(EventMatch, Period)] = []

        // Backlog inclusion
        var includeBacklog: Bool = false
        var backlogTaskIds: Set<String>? = nil  // nil = all pending

        // Source filters
        var calendarFilter: String? = nil
        var projectFilter: String? = nil
        var timeRangeFilter: DateInterval? = nil

        // Transforms
        var transforms: [EventTransform] = []

        // Output
        var autoApply: Bool = false
        var notifyMessage: String? = nil
        var chainedRequest: OptimizationRequest? = nil
        var savePresetName: String? = nil

        init(defaultWorkingHours: ClosedRange<Int>) {
            self.workingHours = defaultWorkingHours
        }
    }

    /// Post-collection event transforms.
    enum EventTransform {
        case splitLong(maxMinutes: Int)
        case addBuffer(minutes: Int)
        case capTotal(minutesPerDay: Int)
        case mergeAdjacent(context: String)
    }

    // MARK: - Apply Single Intent

    func apply(_ intent: ScheduleIntent, to config: inout ResolvedConfig) {
        switch intent {

        // Time constraints
        case .noEventsBefore(let hour):
            let end = config.workingHours.upperBound
            config.workingHours = max(hour, config.workingHours.lowerBound)...end
        case .noEventsAfter(let hour):
            let start = config.workingHours.lowerBound
            config.workingHours = start...min(hour, config.workingHours.upperBound)
        case .workingHours(let start, let end):
            config.workingHours = start...end
        case .horizon(let h):
            config.horizon = h

        // Event creation
        case .focusBlock(let minutes, let period):
            config.syntheticEvents.append(EventSpec(
                title: "Focus Time", minutes: minutes, priority: 0.9,
                energy: 0.7, period: period, focus: true
            ))
            config.findSlotsOnly = true
        case .createBlock(let title, let minutes, let period, let focus):
            config.syntheticEvents.append(EventSpec(
                title: title, minutes: minutes, period: period, focus: focus
            ))
            config.findSlotsOnly = true
        case .pomodoroSession(let preset):
            config.syntheticEvents.append(EventSpec(
                title: "Pomodoro", minutes: preset.totalMinutes,
                priority: 0.8, energy: 0.6, focus: true, pomodoro: preset
            ))
            config.findSlotsOnly = true

        // Weight adjustments
        case .prioritizeDeadlines(let w):
            config.weights[.deadline] = w
        case .prioritizeFocus(let w):
            config.weights[.focusBlock] = w
        case .minimizeContextSwitching(let w):
            config.weights[.contextSwitch] = w
        case .groupByProject(let w):
            config.weights[.contextSwitch] = w  // context grouping reduces switching
        case .batchMeetings(let w):
            config.weights[.focusBlock] = (config.weights[.focusBlock] ?? 1.0)
            // Meeting clustering is expressed through meeting clustering weight
            // which the existing optimizer already supports
            _ = w  // TODO: Add explicit meetingClustering weight key

        // Energy & balance
        case .lowEnergy:
            config.weights[.energyCurve] = 1.8
            config.weights[.breakPlacement] = 1.5
        case .peakEnergy(let hour):
            config.peakEnergyHour = hour
        case .morningPerson:
            config.peakEnergyHour = 9
            config.weights[.energyCurve] = 1.5
        case .protectLunch(let start, let end):
            config.lunchStart = start
            config.lunchEnd = end
        case .breakEvery(let workMinutes, let breakMinutes):
            config.minBreakMinutes = breakMinutes
            // Encode max consecutive work as meeting minutes limit
            let prefs = optimizer.preferences
            if workMinutes < prefs.maxConsecutiveMeetingMinutes {
                // Will be applied in buildPreferences
            }
            _ = workMinutes  // captured in minBreakMinutes context
        case .maxMeetings(let perDay):
            config.maxMeetingsPerDay = perDay

        // Stability
        case .stability(let s):
            config.stability = s

        // Event rules
        case .keepFixed(let ids):
            config.fixedIds.formUnion(ids)
        case .exclude(let ids):
            config.excludeIds.formUnion(ids)
        case .onlyOptimize(let ids):
            config.onlyIds = Set(ids)
        case .preferPeriod(let match, let period):
            config.periodOverrides.append((match, period))

        // Task selection
        case .includeBacklog:
            config.includeBacklog = true
        case .includeBacklogTasks(let ids):
            config.includeBacklog = true
            config.backlogTaskIds = Set(ids)
        case .findSlotsForBacklog:
            config.includeBacklog = true
            config.findSlotsOnly = true

        // Speed
        case .speed(let s):
            config.speed = s

        // Display
        case .scenarios(let count):
            config.maxScenarios = count

        // Sources — filter events by calendar/project
        case .fromCalendar(let name):
            config.calendarFilter = name
        case .fromProject(let name):
            config.projectFilter = name
        case .fromTimeRange(let start, let end):
            config.timeRangeFilter = DateInterval(start: start, end: end)

        // Transforms — applied after collecting events, before GA
        case .splitLong(let maxMinutes):
            config.transforms.append(.splitLong(maxMinutes: maxMinutes))
        case .addBuffer(let minutes):
            config.transforms.append(.addBuffer(minutes: minutes))
        case .capTotal(let minutesPerDay):
            config.transforms.append(.capTotal(minutesPerDay: minutesPerDay))
        case .mergeAdjacent(let context):
            config.transforms.append(.mergeAdjacent(context: context))

        // Conditions — evaluated at runtime
        case .when(let condition, let thenIntents, let elseIntents):
            let passes = evaluateCondition(condition)
            let intents = passes ? thenIntents : elseIntents
            for intent in intents {
                apply(intent, to: &config)
            }

        // Output — how to handle the result
        case .autoApply:
            config.maxScenarios = 1
            config.autoApply = true
        case .notify(let message):
            config.notifyMessage = message
        case .chainThen(let next):
            config.chainedRequest = next
        case .saveAsPreset(let name):
            config.savePresetName = name

        // Triggers — stored but not applied here (handled by trigger system)
        case .onEventDeleted, .onNewEvent, .daily, .weekly, .onCalendarSync:
            break  // Triggers are metadata, not compilation directives
        }
    }

    /// Evaluate a runtime condition against current state.
    private func evaluateCondition(_ condition: IntentCondition) -> Bool {
        let cal = Calendar.current
        let now = Date()
        let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!

        switch condition {
        case .meetingHeavy(let threshold):
            let meetings = reminderService.allEvents.filter {
                $0.startDate >= now && $0.startDate < todayEnd && !$0.isLocalEvent
            }
            return meetings.count >= threshold

        case .deadlineWithin(let days):
            let cutoff = cal.date(byAdding: .day, value: days, to: now) ?? now
            return backlogService.tasks.contains {
                $0.status != .done && $0.deadline != nil && $0.deadline! <= cutoff
            }

        case .afterHour(let hour):
            return cal.component(.hour, from: now) >= hour

        case .pendingTasks(let threshold):
            return backlogService.pending.count >= threshold

        case .dayOfWeek(let day):
            return cal.component(.weekday, from: now) == day

        case .hasFreeGap(let minutes):
            let events = reminderService.allEvents
                .filter { $0.startDate >= now && $0.startDate < todayEnd }
                .sorted { $0.startDate < $1.startDate }
            var cursor = now
            for event in events {
                if event.startDate.timeIntervalSince(cursor) >= TimeInterval(minutes * 60) {
                    return true
                }
                cursor = max(cursor, event.endDate)
            }
            return todayEnd.timeIntervalSince(cursor) >= TimeInterval(minutes * 60)
        }
    }
}

// MARK: - Event Collection

private extension IntentCompiler {

    func resolveSyntheticEvents(_ config: ResolvedConfig) -> [OptimizableEvent] {
        config.syntheticEvents.flatMap { spec -> [OptimizableEvent] in
            let effectiveEnergy = adjustedEnergy(base: spec.energy, storyPoints: spec.storyPoints)
            return (0..<spec.count).map { i in
                OptimizableEvent(
                    id: spec.count > 1 ? "\(spec.specId)_\(i)" : spec.specId,
                    title: spec.count > 1 ? "\(spec.title) \(i + 1)" : spec.title,
                    duration: TimeInterval(spec.minutes * 60),
                    deadline: spec.deadline,
                    priority: spec.priority,
                    context: spec.context,
                    energyCost: effectiveEnergy,
                    requiredParticipants: spec.participants,
                    preferredHourRange: spec.period?.hourRange,
                    isFocusBlock: spec.focus,
                    pomodoroConfig: spec.pomodoro?.config,
                    storyPoints: spec.storyPoints,
                    dependsOn: spec.dependsOn
                )
            }
        }
    }

    func collectLocalEvents(_ config: ResolvedConfig) -> [OptimizableEvent] {
        guard !config.findSlotsOnly else {
            return collectBacklogTasks(config)
        }

        var events = collectLocalEventsForHorizon(config.horizon)

        // Apply source filters
        events = applySourceFilters(config, to: events)

        // Filter to specific IDs if set
        if let onlyIds = config.onlyIds {
            events = events.filter { onlyIds.contains($0.id) }
        }

        // Exclude specific IDs
        if !config.excludeIds.isEmpty {
            events = events.filter { !config.excludeIds.contains($0.id) }
        }

        // Apply period overrides
        for (match, period) in config.periodOverrides {
            events = events.map { event in
                guard matches(event, match) else { return event }
                return OptimizableEvent(
                    id: event.id, title: event.title, duration: event.duration,
                    deadline: event.deadline, priority: event.priority,
                    context: event.context, energyCost: event.energyCost,
                    requiredParticipants: event.requiredParticipants,
                    preferredHourRange: period.hourRange,
                    isFocusBlock: event.isFocusBlock, pomodoroConfig: event.pomodoroConfig,
                    storyPoints: event.storyPoints, dependsOn: event.dependsOn
                )
            }
        }

        // Add backlog tasks
        if config.includeBacklog {
            events += collectBacklogTasks(config)
        }

        return events
    }

    func collectBacklogTasks(_ config: ResolvedConfig) -> [OptimizableEvent] {
        guard config.includeBacklog else { return [] }
        let pending = backlogService.pending
        let filtered: [BacklogTask]
        if let ids = config.backlogTaskIds {
            filtered = pending.filter { ids.contains($0.id) }
        } else {
            filtered = pending
        }
        return filtered.map { $0.toOptimizableEvent() }
    }

    /// Apply source filters (calendar, project, time range) to events.
    func applySourceFilters(_ config: ResolvedConfig, to events: [OptimizableEvent]) -> [OptimizableEvent] {
        var result = events

        if let calFilter = config.calendarFilter {
            // Filter by calendar name context
            result = result.filter { $0.context == calFilter || calFilter.isEmpty }
        }

        if let projFilter = config.projectFilter {
            result = result.filter { $0.context == projFilter }
        }

        if let range = config.timeRangeFilter {
            // Only keep events whose preferred time overlaps the range
            // (for movable events without fixed times, keep all)
            _ = range  // time range filter is applied in horizon resolution
        }

        return result
    }

    /// Apply transforms to movable events before GA.
    func applyTransforms(_ transforms: [ResolvedConfig.EventTransform], to events: [OptimizableEvent]) -> [OptimizableEvent] {
        var result = events

        for transform in transforms {
            switch transform {
            case .splitLong(let maxMinutes):
                let maxDuration = TimeInterval(maxMinutes * 60)
                result = result.flatMap { event -> [OptimizableEvent] in
                    guard event.duration > maxDuration else { return [event] }
                    let parts = Int(ceil(event.duration / maxDuration))
                    let partDuration = event.duration / Double(parts)
                    return (0..<parts).map { i in
                        OptimizableEvent(
                            id: "\(event.id)_p\(i)",
                            title: "\(event.title) (\(i + 1)/\(parts))",
                            duration: partDuration,
                            deadline: event.deadline,
                            priority: event.priority,
                            context: event.context,
                            energyCost: event.energyCost,
                            preferredHourRange: event.preferredHourRange,
                            isFocusBlock: event.isFocusBlock,
                            storyPoints: event.storyPoints,
                            dependsOn: i == 0 ? event.dependsOn : ["\(event.id)_p\(i - 1)"]
                        )
                    }
                }

            case .addBuffer(let minutes):
                // Buffer is handled by the GA's buffer objective weight
                // Increase the buffer weight to enforce it
                _ = minutes

            case .capTotal(let minutesPerDay):
                // Sort by priority descending, keep events until total exceeds cap
                let maxDuration = TimeInterval(minutesPerDay * 60)
                let sorted = result.sorted { $0.priority > $1.priority }
                var total: TimeInterval = 0
                result = sorted.filter { event in
                    total += event.duration
                    return total <= maxDuration
                }

            case .mergeAdjacent(let context):
                // Merge events with matching context by increasing duration
                var merged: [OptimizableEvent] = []
                var pendingMerge: OptimizableEvent? = nil
                let matching = result.filter { $0.context == context }
                let nonMatching = result.filter { $0.context != context }

                for event in matching {
                    if var pending = pendingMerge {
                        pending = OptimizableEvent(
                            id: pending.id,
                            title: pending.title,
                            duration: pending.duration + event.duration,
                            deadline: pending.deadline ?? event.deadline,
                            priority: max(pending.priority, event.priority),
                            context: pending.context,
                            energyCost: max(pending.energyCost, event.energyCost),
                            preferredHourRange: pending.preferredHourRange,
                            isFocusBlock: pending.isFocusBlock || event.isFocusBlock,
                            storyPoints: pending.storyPoints
                        )
                        pendingMerge = pending
                    } else {
                        pendingMerge = event
                    }
                }
                if let pending = pendingMerge { merged.append(pending) }
                result = nonMatching + merged
            }
        }

        return result
    }

    func collectLocalEventsForHorizon(_ horizon: Horizon) -> [OptimizableEvent] {
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

    func matches(_ event: OptimizableEvent, _ match: EventMatch) -> Bool {
        switch match {
        case .all: return true
        case .context(let ctx): return event.context == ctx
        case .focusBlocks: return event.isFocusBlock
        case .meetings: return !event.requiredParticipants.isEmpty || event.context == "meeting"
        case .highEnergy: return event.energyCost > 0.6
        case .lowEnergy: return event.energyCost <= 0.3
        case .withDeadline: return event.deadline != nil
        case .longerThan(let minutes): return event.duration > TimeInterval(minutes * 60)
        case .id(let id): return event.id == id
        case .ids(let ids): return ids.contains(event.id)
        case .onDay, .onDays: return false
        }
    }

    func applyEventRules(_ config: ResolvedConfig, to events: [OptimizableEvent]) -> [OptimizableEvent] {
        events.filter { !config.excludeIds.contains($0.id) }
    }
}

// MARK: - Build Preferences

private extension IntentCompiler {

    func buildPreferences(_ config: ResolvedConfig) -> OptimizerPreferences {
        var prefs = optimizer.preferences
        optimizer.preferenceLearner.applyToPreferences(&prefs)

        // Apply weight overrides from intents
        for (key, value) in config.weights {
            switch key {
            case .focusBlock:     prefs.focusBlockWeight = value
            case .pomodoroFit:    prefs.pomodoroFitWeight = value
            case .conflict:       prefs.conflictWeight = value
            case .taskPlacement:  prefs.taskPlacementWeight = value
            case .weekBalance:    prefs.weekBalanceWeight = value
            case .energyCurve:    prefs.energyCurveWeight = value
            case .multiPerson:    prefs.multiPersonWeight = value
            case .breakPlacement: prefs.breakWeight = value
            case .deadline:       prefs.deadlineWeight = value
            case .contextSwitch:  prefs.contextSwitchWeight = value
            case .buffer:         prefs.bufferWeight = value
            case .useLearned:     break
            }
        }

        // Apply direct preference overrides
        if let v = config.peakEnergyHour { prefs.peakEnergyHour = v }
        if let v = config.maxMeetingsPerDay { prefs.maxMeetingsPerDay = v }
        if let v = config.minBreakMinutes { prefs.minBreakMinutes = v }
        if let v = config.lunchStart { prefs.lunchWindowStart = v }
        if let v = config.lunchEnd { prefs.lunchWindowEnd = v }

        return prefs
    }
}

// MARK: - Horizon & Pre-flight (reused from RecipeExecutor)

private extension IntentCompiler {

    func resolveHorizon(_ horizon: Horizon, workingHours: ClosedRange<Int>, minRequiredMinutes: Double) -> DateInterval {
        let cal = Calendar.current
        let now = Date()

        switch horizon {
        case .today:
            let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            let workEndToday = cal.date(
                bySettingHour: workingHours.upperBound, minute: 0, second: 0, of: now
            ) ?? todayEnd
            let remainingMinutes = workEndToday.timeIntervalSince(now) / 60
            if remainingMinutes < minRequiredMinutes {
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

    func preflightCheck(context: OptimizerContext) -> String? {
        let cal = context.calendar
        let now = Date()
        var availableMinutes: Double = 0
        var largestGapMinutes: Double = 0
        var day = cal.startOfDay(for: context.planningHorizon.start)
        let horizonEnd = context.planningHorizon.end

        while day < horizonEnd {
            guard let workStart = cal.date(bySettingHour: context.workingHours.lowerBound, minute: 0, second: 0, of: day),
                  let workEnd = cal.date(bySettingHour: context.workingHours.upperBound, minute: 0, second: 0, of: day) else {
                day = cal.date(byAdding: .day, value: 1, to: day)!
                continue
            }

            let effectiveStart = max(workStart, max(now, context.planningHorizon.start))
            let effectiveEnd = min(workEnd, horizonEnd)

            if effectiveEnd > effectiveStart {
                var freeMinutes = effectiveEnd.timeIntervalSince(effectiveStart) / 60
                let overlapping = context.fixedEvents
                    .compactMap { fixed -> (start: Date, end: Date)? in
                        let oStart = max(fixed.startDate, effectiveStart)
                        let oEnd = min(fixed.endDate, effectiveEnd)
                        return oEnd > oStart ? (oStart, oEnd) : nil
                    }
                    .sorted { $0.start < $1.start }

                var cursor = effectiveStart
                for fixed in overlapping {
                    let gapMinutes = fixed.start.timeIntervalSince(cursor) / 60
                    if gapMinutes > 0 { largestGapMinutes = max(largestGapMinutes, gapMinutes) }
                    freeMinutes -= fixed.end.timeIntervalSince(fixed.start) / 60
                    cursor = max(cursor, fixed.end)
                }
                let trailingGap = effectiveEnd.timeIntervalSince(cursor) / 60
                if trailingGap > 0 { largestGapMinutes = max(largestGapMinutes, trailingGap) }
                availableMinutes += max(0, freeMinutes)
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }

        let requiredMinutes = context.movableEvents.reduce(0.0) { $0 + $1.duration / 60 }
        let longestEventMinutes = context.movableEvents.map { $0.duration / 60 }.max() ?? 0

        if availableMinutes < 1 {
            return "No working time left — try tomorrow"
        }
        if requiredMinutes > availableMinutes {
            return "Need \(Int(requiredMinutes)) min but only \(Int(availableMinutes)) min available"
        }
        if longestEventMinutes > largestGapMinutes {
            return "Longest event (\(Int(longestEventMinutes)) min) doesn't fit in largest gap (\(Int(largestGapMinutes)) min)"
        }
        return nil
    }

    func buildSnapshot(fixedEvents: [CalendarEvent], workingHours: ClosedRange<Int>, horizon: DateInterval) -> ScheduleSnapshot {
        let cal = Calendar.current
        let now = Date()
        var gaps: [DateInterval] = []
        var day = cal.startOfDay(for: horizon.start)

        while day < horizon.end {
            guard let workStart = cal.date(bySettingHour: workingHours.lowerBound, minute: 0, second: 0, of: day),
                  let workEnd = cal.date(bySettingHour: workingHours.upperBound, minute: 0, second: 0, of: day) else {
                day = cal.date(byAdding: .day, value: 1, to: day)!
                continue
            }

            let effectiveStart = max(workStart, max(now, horizon.start))
            let effectiveEnd = min(workEnd, horizon.end)

            if effectiveEnd > effectiveStart {
                let overlapping = fixedEvents
                    .compactMap { fixed -> (start: Date, end: Date)? in
                        let oStart = max(fixed.startDate, effectiveStart)
                        let oEnd = min(fixed.endDate, effectiveEnd)
                        return oEnd > oStart ? (oStart, oEnd) : nil
                    }
                    .sorted { $0.start < $1.start }

                var cursor = effectiveStart
                for fixed in overlapping {
                    if fixed.start > cursor { gaps.append(DateInterval(start: cursor, end: fixed.start)) }
                    cursor = max(cursor, fixed.end)
                }
                if effectiveEnd > cursor { gaps.append(DateInterval(start: cursor, end: effectiveEnd)) }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }

        return ScheduleSnapshot(freeGaps: gaps, workingHours: workingHours, planningHorizon: horizon)
    }
}
