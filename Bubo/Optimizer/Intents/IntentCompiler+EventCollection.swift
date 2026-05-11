import Foundation

// MARK: - IntentCompiler event collection + transforms
//
// Once the intent pass has produced a `ResolvedConfig`, this extension
// turns it into concrete event lists for the GA: pulls fixed events
// from calendars, the backlog tasks the user wanted included, and
// synthetic events the intents requested. Then applies source filters
// (calendar/project), event rules (keep/exclude/preferPeriod), and the
// post-collection transforms (split-long, add-buffer, cap-total,
// merge-adjacent).

extension IntentCompiler {

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
                    pomodoroConfig: spec.pomodoroConfig,
                    storyPoints: spec.storyPoints,
                    dependsOn: spec.dependsOn,
                    reservedTaskIds: spec.reservedTaskIds
                )
            }
        }
    }

    func collectLocalEvents(_ config: ResolvedConfig) -> [OptimizableEvent] {
        guard !config.findSlotsOnly else {
            // Backlog tasks are collected separately and capped in execute()
            return []
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
                    storyPoints: event.storyPoints, dependsOn: event.dependsOn,
                    reservedTaskIds: event.reservedTaskIds
                )
            }
        }

        // Backlog tasks are collected separately and capped in execute()
        return events
    }

    func collectBacklogTasks(_ config: ResolvedConfig) -> [OptimizableEvent] {
        guard config.includeBacklog else { return [] }
        // Tasks consumed by an auto-pomodoro spec (see
        // `resolveAutoPomodoros`) must not be scheduled a second time as
        // standalone backlog events — the synthetic pomodoro already
        // carries the task's id, title, and shape.
        let reservedBySynthetic = Set(
            config.syntheticEvents.compactMap { spec in
                spec.autoPomodoro ? spec.specId : nil
            }
        )
        let candidates = backlogService.schedulable.filter { !reservedBySynthetic.contains($0.id) }
        var filtered: [BacklogTask]
        if let ids = config.backlogTaskIds {
            filtered = candidates.filter { ids.contains($0.id) }
        } else {
            filtered = candidates
        }
        
        if let limit = config.limitToTopTasksCount {
            // Preserve the user's backlog order — `schedulable` already reflects
            // the drag-sorted storage order, so "top N" means the first N rows
            // the user sees, not a re-sort by priority/deadline.
            filtered = Array(filtered.prefix(limit))
        }

        // Tag each event with its position in the filtered backlog so
        // `BacklogOrderObjective` can reward schedules that match the user's
        // drag order. Index is 0-based and dense over `filtered`.
        return filtered.enumerated().map { idx, task in
            task.toOptimizableEvent(backlogIndex: idx)
        }
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

        return result
    }

    /// Apply transforms to movable events before GA.
    func applyTransforms(_ transforms: [EventTransform], to events: [OptimizableEvent]) -> [OptimizableEvent] {
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
                            dependsOn: i == 0 ? event.dependsOn : ["\(event.id)_p\(i - 1)"],
                            // Preserve backlog order: every split part inherits
                            // the parent's backlog position so
                            // `BacklogOrderObjective` keeps a signal after the
                            // transform. Without this, splitting any task
                            // wipes `backlogIndex` across the whole request
                            // and the objective silently flatlines at 1.0.
                            backlogIndex: event.backlogIndex
                        )
                    }
                }

            case .addBuffer(let minutes):
                let bufferDuration = TimeInterval(minutes * 60)
                result = result.map { event in
                    OptimizableEvent(
                        id: event.id, title: event.title,
                        duration: event.duration + bufferDuration,
                        deadline: event.deadline, priority: event.priority,
                        context: event.context, energyCost: event.energyCost,
                        preferredHourRange: event.preferredHourRange,
                        isFocusBlock: event.isFocusBlock,
                        storyPoints: event.storyPoints,
                        dependsOn: event.dependsOn,
                        isDroppable: event.isDroppable,
                        backlogIndex: event.backlogIndex
                    )
                }

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
                        // When two backlog tasks merge, inherit the earliest
                        // backlog position so the merged super-event still
                        // carries a sensible order for the objective. nil if
                        // neither side was from the backlog.
                        let mergedIdx: Int?
                        switch (pending.backlogIndex, event.backlogIndex) {
                        case let (.some(a), .some(b)): mergedIdx = min(a, b)
                        case let (.some(a), .none): mergedIdx = a
                        case let (.none, .some(b)): mergedIdx = b
                        case (.none, .none): mergedIdx = nil
                        }
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
                            storyPoints: pending.storyPoints,
                            backlogIndex: mergedIdx
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

    /// Safety net for backlog tasks whose duration is larger than a single
    /// working day can hold. Each oversized task is split into equal-sized
    /// chunks that each fit in one day's working window, with a sequential
    /// `dependsOn` chain so the GA schedules them in order across
    /// consecutive days. Runs after user-configured `.splitLong`
    /// transforms, so an explicit narrower split keeps its own naming and
    /// this pass is a no-op on its output.
    nonisolated static func splitOversizedBacklogTasks(
        _ events: [OptimizableEvent],
        workingHours: ClosedRange<Int>
    ) -> [OptimizableEvent] {
        let windowHours = workingHours.upperBound - workingHours.lowerBound
        guard windowHours > 0 else { return events }
        let maxDuration = TimeInterval(windowHours * 3600)

        return events.flatMap { event -> [OptimizableEvent] in
            guard event.duration > maxDuration else { return [event] }
            let parts = Int(ceil(event.duration / maxDuration))
            let partDuration = event.duration / Double(parts)
            // All chunks of the same task share `groupId` so
            // `AtomicGroupConstraint` (soft) nudges the GA toward
            // including-or-dropping the group as a unit — partial plans
            // are still allowed when the full group doesn't fit, just
            // discounted.
            let group = event.groupId ?? event.id
            return (0..<parts).map { i in
                OptimizableEvent(
                    id: "\(event.id)_p\(i)",
                    title: "\(event.title) (\(i + 1)/\(parts))",
                    duration: partDuration,
                    deadline: event.deadline,
                    priority: event.priority,
                    context: event.context,
                    energyCost: event.energyCost,
                    requiredParticipants: event.requiredParticipants,
                    preferredHourRange: event.preferredHourRange,
                    isFocusBlock: event.isFocusBlock,
                    pomodoroConfig: event.pomodoroConfig,
                    earliestStart: event.earliestStart,
                    storyPoints: event.storyPoints,
                    dependsOn: i == 0 ? event.dependsOn : ["\(event.id)_p\(i - 1)"],
                    isDroppable: event.isDroppable,
                    reservedTaskIds: event.reservedTaskIds,
                    backlogIndex: event.backlogIndex,
                    groupId: group
                )
            }
        }
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
