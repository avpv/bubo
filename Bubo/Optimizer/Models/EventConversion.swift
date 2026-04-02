import Foundation

// MARK: - CalendarEvent <-> OptimizableEvent Conversion

extension CalendarEvent {

    /// Resolve a unified context by combining all available signals.
    /// All non-nil parts are joined with "/" to form a composite key,
    /// so events sharing any subset of signals will have overlapping prefixes.
    ///
    /// Examples:
    ///   calendar="Work", colorTag=blue("backend"), context="API"  → "Work/backend/API"
    ///   calendar="Work", colorTag=blue(no label),  context=nil    → "Work/blue"
    ///   calendar="Work", colorTag=nil,             context=nil    → "Work"
    ///   calendar=nil,    colorTag=nil,             context="design" → "design"
    func resolvedContext(override: String? = nil) -> String? {
        var parts: [String] = []
        if let name = calendarName, !name.isEmpty {
            parts.append(name)
        }
        if let tag = colorTag {
            // User-configured label takes priority, raw color name as fallback
            parts.append(tag.contextLabel ?? tag.rawValue)
        }
        if let ctx = override ?? context, !ctx.isEmpty {
            parts.append(ctx)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// Convert a CalendarEvent into an OptimizableEvent for the optimizer.
    /// Only makes sense for events the user can move (local events).
    func toOptimizableEvent(
        priority: Double = 0.5,
        context: String? = nil,
        energyCost: Double = 0.5,
        deadline: Date? = nil,
        requiredParticipants: [String] = [],
        preferredHourRange: ClosedRange<Int>? = nil
    ) -> OptimizableEvent {
        let duration = endDate.timeIntervalSince(startDate)

        let isFocus = eventType == .pomodoro
            || title.localizedCaseInsensitiveContains("focus")
            || title.localizedCaseInsensitiveContains("deep work")

        let pomConfig: PomodoroConfig? = {
            guard eventType == .pomodoro,
                  let rule = recurrenceRule, rule.isPomodoro else { return nil }
            let workMinutes = rule.interval
            let rounds: Int
            if case .afterCount(let n) = rule.end { rounds = n } else { rounds = 4 }
            return PomodoroConfig(
                workMinutes: workMinutes,
                breakMinutes: max(1, workMinutes / 5),
                rounds: rounds,
                longBreakMinutes: rule.pomodoroLongBreak
            )
        }()

        let inferredEnergy: Double = {
            if isFocus || eventType == .pomodoro { return 0.8 }
            if meetingLink != nil { return 0.6 }
            return energyCost
        }()

        return OptimizableEvent(
            id: id,
            title: title,
            duration: duration,
            deadline: deadline,
            priority: priority,
            context: resolvedContext(override: context),
            energyCost: inferredEnergy,
            requiredParticipants: requiredParticipants,
            preferredHourRange: preferredHourRange,
            isFocusBlock: isFocus,
            pomodoroConfig: pomConfig
        )
    }
}

extension ScheduleGene {

    /// Convert a ScheduleGene back into a CalendarEvent.
    func toCalendarEvent(
        title: String? = nil,
        calendarName: String? = "Optimizer",
        eventType: EventType = .standard,
        colorTag: EventColorTag? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: eventId,
            title: title ?? self.title,
            startDate: startTime,
            endDate: endTime,
            location: nil,
            description: nil,
            calendarName: calendarName,
            eventType: eventType,
            colorTag: colorTag
        )
    }
}

extension ScheduleScenario {

    /// Convert a scenario into displayable CalendarEvents.
    func toCalendarEvents(using movableEvents: [OptimizableEvent]) -> [CalendarEvent] {
        genes.compactMap { gene in
            let event = movableEvents.first { $0.id == gene.eventId }
            return gene.toCalendarEvent(
                title: event?.title ?? gene.eventId,
                eventType: event?.pomodoroConfig != nil ? .pomodoro : .standard
            )
        }
    }
}
