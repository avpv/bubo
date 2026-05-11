import Foundation

// MARK: - IntentCompiler apply pipeline
//
// The middle of the pipeline: an `IntentCompiler.execute(...)` call from
// `IntentCompiler.swift` walks each intent in order through `apply(_:to:)`,
// which updates a `ResolvedConfig` IR. This file owns the IR struct, the
// per-intent application logic, condition evaluation, and the "auto
// pomodoro" resolver that synthesises pomodoro sessions when the user
// only said "schedule some focus time".
//
// Was `private extension IntentCompiler` in the original file; relaxed
// to `internal extension` so the main `execute(...)` and adjacent
// extension files (`+EventCollection`, `+Preferences`, `+Horizon`) keep
// access without crossing privacy boundaries.

extension IntentCompiler {

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
        var maxConsecutiveWorkMinutes: Int? = nil
        var meetingClusteringWeight: Double? = nil
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
        var limitToTopTasksCount: Int? = nil

        // Task ordering
        var taskOrderStrategy: TaskOrderStrategy? = nil
        var flexMinDuration: Int? = nil
        var flexMaxDuration: Int? = nil

        // Adaptive
        var maxExtraTasks: Int? = nil
        var overflowToTomorrow: Bool = false
        /// Set by the `.skipWeekends` intent. The compiler translates it
        /// into a `workingDays = Mon–Fri` override when building the
        /// final `OptimizerPreferences`.
        var skipWeekends: Bool = false

        // Source filters
        var calendarFilter: String? = nil
        var projectFilter: String? = nil

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

    func apply(_ intent: ScheduleIntent, to config: inout ResolvedConfig, requestId: String = "-") {
        // Per-intent trace, gated at the OSLog level so the 60-case switch
        // below doesn't pay string formatting when debug is filtered out.
        // Emitted at `.debug` deliberately: this is developer-facing
        // instrumentation, not a support signal — the aggregate
        // `intents_received` line above is what investigators grep for.
        if intentsOSLog.isEnabled(type: .debug) {
            // `caseName` is the stable enum tag (no user data, .public);
            // `label` inlines user titles like `createBlock(title:)`.
            // Temporarily `.public` for plan-week slowness diagnosis.
            logger.debug("intent_applied rid=\(requestId, privacy: .public) case=\(intent.caseName, privacy: .public) detail=\(intent.label, privacy: .public)")
        }
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
        case .pomodoroSession:
            // Placeholder minutes — resolveAutoPomodoros(&config) rewrites
            // both `minutes` and `pomodoroConfig` once signals are known.
            config.syntheticEvents.append(EventSpec(
                title: "Pomodoro", minutes: 120,
                priority: 0.8, energy: 0.6, focus: true, autoPomodoro: true
            ))
            config.findSlotsOnly = true
        case .focusBurst(let maxTasks, let contextFilter):
            // Packed pomodoro — marker tells resolveAutoPomodoros to
            // consume up to `maxTasks` backlog rows (optionally filtered
            // by context) instead of just the top one. Title, minutes,
            // and `reservedTaskIds` are rewritten once the backlog pack
            // is chosen.
            var spec = EventSpec(
                title: "Focus burst", minutes: 120,
                priority: 0.8, energy: 0.6, focus: true,
                autoPomodoro: true,
                autoFocusBurstMax: max(1, min(maxTasks, 8))
            )
            spec.context = contextFilter
            config.syntheticEvents.append(spec)
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
            config.meetingClusteringWeight = w

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
            config.maxConsecutiveWorkMinutes = workMinutes
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
            let idSet = Set(ids)
            if config.backlogTaskIds == nil {
                config.backlogTaskIds = idSet
            } else {
                config.backlogTaskIds?.formUnion(idSet)
            }
        case .limitToTopTasks(let c):
            config.includeBacklog = true
            config.limitToTopTasksCount = c
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
            let cal = Calendar.current
            let startHour = cal.component(.hour, from: start)
            let endHour = cal.component(.hour, from: end)
            config.workingHours = max(startHour, config.workingHours.lowerBound)...min(endHour, config.workingHours.upperBound)

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

        // Smart scheduling
        case .contingencyBuffer(let percent):
            // Reserve % of working time — reduce available slots
            let totalMinutes = Double((config.workingHours.upperBound - config.workingHours.lowerBound) * 60)
            let reserveMinutes = Int(totalMinutes * Double(percent) / 100.0)
            config.transforms.append(.capTotal(minutesPerDay: Int(totalMinutes) - reserveMinutes))

        case .focusProtection(let bufferMinutes):
            config.minBreakMinutes = max(config.minBreakMinutes ?? 0, bufferMinutes)
            config.weights[.focusBlock] = max(config.weights[.focusBlock] ?? 1.0, 1.5)

        case .meetingPrep(let minutes):
            config.transforms.append(.addBuffer(minutes: minutes))

        case .windDown(_):
            config.weights[.energyCurve] = max(config.weights[.energyCurve] ?? 1.0, 1.8)

        case .taskOrder(let strategy):
            config.taskOrderStrategy = strategy

        case .minGap(let minutes):
            config.minBreakMinutes = max(config.minBreakMinutes ?? 0, minutes)

        case .flexDuration(let minMinutes, let maxMinutes):
            // Store range — applied during event collection
            config.flexMinDuration = minMinutes
            config.flexMaxDuration = maxMinutes

        case .likeYesterday:
            // Copy yesterday's time structure via stability
            config.stability = .conservative

        case .halfDay(let mode):
            switch mode {
            case .morningOnly:
                let midpoint = (config.workingHours.lowerBound + config.workingHours.upperBound) / 2
                config.workingHours = config.workingHours.lowerBound...midpoint
            case .afternoonOnly:
                let midpoint = (config.workingHours.lowerBound + config.workingHours.upperBound) / 2
                config.workingHours = midpoint...config.workingHours.upperBound
            }

        case .warmUp(let minutes):
            // Add a light warm-up block before the first task
            config.syntheticEvents.append(EventSpec(
                title: "Warm-up", minutes: minutes, priority: 0.3,
                energy: 0.2, period: .morning
            ))

        case .coolDown(let minutes):
            // Add a cool-down block after the last hard task
            config.syntheticEvents.append(EventSpec(
                title: "Cool-down", minutes: minutes, priority: 0.3,
                energy: 0.1, period: .evening
            ))

        case .travelBuffer(let minutes):
            config.transforms.append(.addBuffer(minutes: minutes))

        case .endOfDayReview(let minutes):
            config.syntheticEvents.append(EventSpec(
                title: "Review", minutes: minutes, priority: 0.4,
                energy: 0.3, period: .evening
            ))

        case .matchEnergyCurve:
            config.weights[.energyCurve] = 2.5

        case .timeBox(let maxMinutes):
            config.transforms.append(.splitLong(maxMinutes: maxMinutes))

        // Social
        case .syncWith:
            break  // Requires external availability API — stored as metadata
        case .officeHours(let start, let end):
            config.syntheticEvents.append(EventSpec(
                title: "Office Hours", minutes: (end - start) * 60,
                priority: 0.4, energy: 0.3
            ))
        case .pairWork(_, let minutes):
            config.syntheticEvents.append(EventSpec(
                title: "Pair Work", minutes: minutes,
                priority: 0.7, energy: 0.6, focus: true
            ))
        case .noOverlap:
            // Already enforced by NoOverlapConstraint — this is a no-op signal
            break

        // Health
        case .microBreak(_, let durationMinutes):
            config.minBreakMinutes = max(config.minBreakMinutes ?? 0, durationMinutes)
            config.weights[.breakPlacement] = max(config.weights[.breakPlacement] ?? 1.0, 2.0)
        case .walkBreak(_, let durationMinutes):
            config.minBreakMinutes = max(config.minBreakMinutes ?? 0, durationMinutes)
        case .pinAt(let title, let hour, let minutes):
            let cal = Calendar.current
            let now = Date()
            let pinDate = cal.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
            config.syntheticEvents.append(EventSpec(
                title: title, minutes: minutes, priority: 1.0,
                energy: 0.3, startOffsetMinutes: max(0, Int(pinDate.timeIntervalSince(now) / 60))
            ))
        case .noScreensAfter(let hour):
            let start = config.workingHours.lowerBound
            config.workingHours = start...min(hour, config.workingHours.upperBound)

        // Context batching
        case .batchByTool:
            config.weights[.contextSwitch] = max(config.weights[.contextSwitch] ?? 1.0, 2.0)
        case .deepShallowSplit(let deepPeriod, _):
            config.periodOverrides.append((.highEnergy, deepPeriod))
        case .groupByLocation:
            config.weights[.contextSwitch] = max(config.weights[.contextSwitch] ?? 1.0, 1.8)
        case .uninterruptedBlock(_, let hours):
            config.syntheticEvents.append(EventSpec(
                title: "Focus Block", minutes: hours * 60,
                priority: 0.8, energy: 0.7, focus: true
            ))
            config.findSlotsOnly = true

        // Adaptive
        case .stretchGoals(let maxExtra):
            config.includeBacklog = true
            config.maxExtraTasks = maxExtra
        case .overflowToTomorrow:
            config.overflowToTomorrow = true
        case .energyCheckIn:
            break  // Prompt scheduling handled by EnergyCheckInService

        // Temporal scope
        case .todayOnly(let inner):
            apply(inner, to: &config)
        case .until(_, let inner):
            apply(inner, to: &config)
        case .skipWeekends:
            config.skipWeekends = true

        // Triggers — stored but not applied here (handled by trigger system)
        case .onEventDeleted, .onNewEvent, .daily, .weekly, .onCalendarSync:
            break
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
                $0.status != .done
                    && $0.status != .frozen
                    && $0.deadline != nil
                    && $0.deadline! <= cutoff
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

    // MARK: - Auto Pomodoro Resolution

    /// Replace any `.auto` pomodoro spec in `config.syntheticEvents` with a
    /// concrete `PomodoroConfig` produced by `PomodoroConfigResolver`. Called
    /// after the intent loop so every signal (peak energy, working hours,
    /// backlog, calendar) is already settled.
    func resolveAutoPomodoros(in config: inout ResolvedConfig) {
        guard config.syntheticEvents.contains(where: { $0.autoPomodoro }) else {
            return
        }

        for i in config.syntheticEvents.indices where config.syntheticEvents[i].autoPomodoro {
            var spec = config.syntheticEvents[i]

            // Pick the backlog pack: 1 task for .pomodoroSession, up to
            // `autoFocusBurstMax` for .focusBurst. Optional `spec.context`
            // narrows the pack to tasks in the same project/tag.
            let maxTasks = spec.autoFocusBurstMax ?? 1
            let pack = pickBacklogPack(maxTasks: maxTasks, contextFilter: spec.context)

            // Phase A (pre-GA): resolver decides duration + shape.
            // Signals are built per-spec so the estimate reflects the
            // pack's total work, not just the top task.
            var signals = buildPomodoroSignals(config)
            if !pack.isEmpty {
                signals.taskEstimateMinutes = pack.reduce(0) { $0 + $1.durationMinutes }
                signals.taskStoryPoints = pack.compactMap(\.storyPoints).max()
                if let firstDeadline = pack.compactMap(\.deadline).min() {
                    let cal = Calendar.current
                    let days = cal.dateComponents(
                        [.day],
                        from: cal.startOfDay(for: Date()),
                        to: cal.startOfDay(for: firstDeadline)
                    ).day
                    signals.deadlineDaysAway = days
                }
            }

            let duration = PomodoroConfigResolver.resolveDuration(signals: signals)
            var shape = PomodoroConfigResolver.resolveShape(
                totalMinutes: duration,
                startHour: signals.startHour,
                signals: signals
            )

            // Clamp the shape to the pack size when packing — one task
            // per work round keeps the per-round labelling meaningful.
            if !pack.isEmpty, shape.rounds > pack.count {
                shape = PomodoroConfig(
                    workMinutes: shape.workMinutes,
                    breakMinutes: shape.breakMinutes,
                    rounds: pack.count,
                    longBreakMinutes: pack.count >= 3 ? shape.longBreakMinutes : 0
                )
            }

            spec.pomodoroConfig = shape
            spec.minutes = shape.totalMinutes

            // Bind the chosen tasks to the spec.
            if let first = pack.first {
                spec.specId = first.id
                spec.storyPoints = first.storyPoints
                spec.deadline = first.deadline
                spec.reservedTaskIds = pack.map(\.id)
                spec.title = focusTitle(for: pack)
            }

            config.syntheticEvents[i] = spec
        }
    }

    /// Delegates to `BacklogTaskCohesion.buildPack`, which owns the
    /// full filter-then-cohesion policy for focus-burst packing.
    private func pickBacklogPack(maxTasks: Int, contextFilter: String?) -> [BacklogTask] {
        BacklogTaskCohesion.buildPack(
            from: backlogService.schedulable,
            maxTasks: maxTasks,
            contextFilter: contextFilter
        )
    }

    /// User-facing title for a packed session.
    /// - 1 task → the task's own title.
    /// - 2 tasks → "A + B".
    /// - 3+ tasks → "A + 2 more".
    private func focusTitle(for pack: [BacklogTask]) -> String {
        let titles = pack.map { $0.title.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        switch titles.count {
        case 0: return "Focus burst"
        case 1: return titles[0]
        case 2: return "\(titles[0]) + \(titles[1])"
        default: return "\(titles[0]) + \(titles.count - 1) more"
        }
    }

    private func buildPomodoroSignals(_ config: ResolvedConfig) -> PomodoroResolveSignals {
        var signals = PomodoroResolveSignals()

        let cal = Calendar.current
        let now = Date()
        signals.startHour = cal.component(.hour, from: now)
        signals.peakEnergyHour = config.peakEnergyHour
        signals.isLowEnergy = (config.weights[.energyCurve] ?? 0) >= 1.8
        signals.wantsDeepWork = (config.weights[.focusBlock] ?? 0) >= 2.0

        signals.availableMinutes = largestFreeGapMinutes(config: config, now: now)
        signals.learnedConfig = pomodoroHistory?.learnedConfig(forHour: signals.startHour)

        if let task = topBacklogCandidate() {
            signals.taskEstimateMinutes = task.durationMinutes
            signals.taskStoryPoints = task.storyPoints
            if let deadline = task.deadline {
                let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: deadline)).day
                signals.deadlineDaysAway = days
            }
        }

        return signals
    }

    /// Largest continuous free window in minutes across the full planning
    /// horizon (today, tomorrow, or the next 7 days). Returns `nil` when
    /// the scan produces no usable window so the resolver falls back to
    /// its own target-duration logic.
    private func largestFreeGapMinutes(config: ResolvedConfig, now: Date) -> Int? {
        let days: Int
        switch config.horizon {
        case .today:    days = 1
        case .tomorrow: days = 2   // today + tomorrow
        case .week:     days = 7
        }

        let cal = Calendar.current
        var largest: TimeInterval = 0
        for offset in 0..<days {
            guard
                let base = cal.date(byAdding: .day, value: offset, to: now),
                let dayStart = cal.date(bySettingHour: config.workingHours.lowerBound, minute: 0, second: 0, of: base),
                let dayEnd = cal.date(bySettingHour: config.workingHours.upperBound, minute: 0, second: 0, of: base)
            else { continue }

            let scanStart = offset == 0 ? max(now, dayStart) : dayStart
            guard scanStart < dayEnd else { continue }

            let events = reminderService.allEvents
                .filter { $0.endDate > scanStart && $0.startDate < dayEnd }
                .sorted { $0.startDate < $1.startDate }

            var cursor = scanStart
            for event in events {
                let gap = event.startDate.timeIntervalSince(cursor)
                if gap > largest { largest = gap }
                cursor = max(cursor, event.endDate)
            }
            let tail = dayEnd.timeIntervalSince(cursor)
            if tail > largest { largest = tail }
        }

        let minutes = Int(largest / 60)
        return minutes > 0 ? minutes : nil
    }

    /// Highest-priority schedulable backlog task — the most likely target for
    /// the pomodoro session. Uses the service's natural ordering so it
    /// matches what `collectBacklogTasks` would pick.
    private func topBacklogCandidate() -> BacklogTask? {
        backlogService.schedulable.first
    }
}
