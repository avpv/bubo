import Foundation

// MARK: - IntentGraph static rules catalog
//
// Pure static facts about `ScheduleIntent` — phase classification,
// dependency edges, conflict reasons, known-intent suggestions. Extracted
// from `IntentGraph.swift` so the graph-builder, reachability, and
// topological-sort core stays in one file and the rules table stays in
// another. Every entry is data, not behaviour; mutations belong on the
// graph itself.

extension IntentGraph {

    // MARK: - Phase Classification

    static func phase(for intent: ScheduleIntent) -> Phase {
        switch intent {
        // Trigger
        case .onEventDeleted, .onNewEvent, .daily, .weekly, .onCalendarSync:
            return .trigger
        // Source
        case .fromCalendar, .fromProject, .fromTimeRange:
            return .source
        // Context
        case .noEventsBefore, .noEventsAfter, .workingHours, .horizon:
            return .context
        // Tasks
        case .includeBacklog, .includeBacklogTasks, .limitToTopTasks, .findSlotsForBacklog:
            return .tasks
        // Create
        case .focusBlock, .createBlock, .pomodoroSession, .focusBurst:
            return .create
        // Transform
        case .splitLong, .addBuffer, .capTotal, .mergeAdjacent:
            return .transform
        // Weights
        case .prioritizeDeadlines, .prioritizeFocus, .minimizeContextSwitching,
             .groupByProject, .batchMeetings:
            return .weights
        // Energy
        case .lowEnergy, .peakEnergy, .morningPerson, .protectLunch,
             .breakEvery, .maxMeetings,
             .contingencyBuffer, .focusProtection, .meetingPrep, .windDown,
             .warmUp, .coolDown, .travelBuffer, .endOfDayReview,
             .likeYesterday, .halfDay, .matchEnergyCurve,
             .microBreak, .walkBreak, .noScreensAfter:
            return .energy
        // Social
        case .syncWith, .officeHours, .pairWork, .noOverlap:
            return .context
        // Create (pinned events)
        case .pinAt:
            return .create
        // Rules
        case .keepFixed, .exclude, .onlyOptimize, .preferPeriod, .stability,
             .taskOrder, .minGap, .flexDuration, .timeBox,
             .batchByTool, .deepShallowSplit, .groupByLocation, .uninterruptedBlock:
            return .rules
        // Output
        case .stretchGoals, .overflowToTomorrow, .energyCheckIn:
            return .output
        // Temporal scope → context phase
        case .todayOnly, .until, .skipWeekends:
            return .context
        // Condition
        case .when:
            return .condition
        // Config
        case .speed, .scenarios:
            return .config
        // Output
        case .autoApply, .notify, .chainThen, .saveAsPreset:
            return .output
        }
    }

    // MARK: - Dependency Rules

    /// Required dependencies: if you add X, you need Y.
    static func dependencies(for intent: ScheduleIntent) -> [ScheduleIntent] {
        switch intent {
        case .prioritizeDeadlines:
            return [.includeBacklog]
        case .findSlotsForBacklog:
            return [.includeBacklog]
        case .groupByProject:
            return [.includeBacklog]
        case .splitLong:
            return [.includeBacklog]
        case .mergeAdjacent:
            return [.includeBacklog]
        case .chainThen:
            return [.autoApply]  // chains need auto-apply to proceed
        default:
            return []
        }
    }

    /// Soft suggestions: if you add X, you might want Y.
    static func suggestions(for intent: ScheduleIntent) -> [ScheduleIntent] {
        switch intent {
        case .focusBlock:
            return [.prioritizeFocus(), .minimizeContextSwitching(), .focusProtection(bufferMinutes: 15), .warmUp(minutes: 10)]
        case .lowEnergy:
            return [.breakEvery(workMinutes: 45, breakMinutes: 15), .protectLunch(), .maxMeetings(perDay: 3)]
        case .morningPerson:
            return [.peakEnergy(hour: 9)]
        case .includeBacklog:
            return [.prioritizeDeadlines()]
        case .batchMeetings:
            return [.protectLunch()]
        case .pomodoroSession, .focusBurst:
            return [.prioritizeFocus()]
        case .splitLong:
            return [.addBuffer(minutes: 5)]
        case .capTotal:
            return [.breakEvery(workMinutes: 60, breakMinutes: 10)]
        case .daily:
            return [.autoApply]  // daily triggers should auto-apply
        case .onEventDeleted:
            return [.stability(.conservative), .autoApply]
        case .fromProject:
            return [.groupByProject()]
        case .meetingPrep:
            return [.travelBuffer(minutes: 15)]
        case .halfDay(.morningOnly):
            return [.morningPerson]
        case .matchEnergyCurve:
            return [.peakEnergy(hour: 10)]
        case .microBreak:
            return [.walkBreak(afterMinutes: 90, durationMinutes: 10)]
        case .deepShallowSplit:
            return [.minimizeContextSwitching(), .matchEnergyCurve]
        case .uninterruptedBlock:
            return [.focusProtection(bufferMinutes: 15), .minimizeContextSwitching()]
        case .officeHours:
            return [.batchMeetings()]
        case .overflowToTomorrow:
            return [.includeBacklog]
        case .stretchGoals:
            return [.includeBacklog]
        default:
            return []
        }
    }

    // MARK: - Conflict Rules

    /// Returns a human-readable reason if two intents conflict, nil if compatible.
    static func conflictReason(_ a: ScheduleIntent, _ b: ScheduleIntent) -> String? {
        switch (a, b) {
        case (.noEventsBefore(let h), .morningPerson) where h >= 11,
             (.morningPerson, .noEventsBefore(let h)) where h >= 11:
            return "Morning blocked until \(h):00 but morning schedule requested"

        case (.noEventsBefore(let bh), .noEventsAfter(let ah)),
             (.noEventsAfter(let ah), .noEventsBefore(let bh)):
            if ah - bh < 2 {
                return "Working window only \(ah - bh)h — too short"
            }
            return nil

        case (.lowEnergy, .prioritizeFocus(let w)),
             (.prioritizeFocus(let w), .lowEnergy):
            if w > 1.5 {
                return "Low energy conflicts with aggressive focus (weight \(w))"
            }
            return nil

        case (.noEventsBefore(let h), .focusBlock(_, let period)),
             (.focusBlock(_, let period), .noEventsBefore(let h)):
            if let p = period, p == .morning && h >= 11 {
                return "Morning focus blocked by noEventsBefore(\(h))"
            }
            return nil

        case (.stability(.full), .stability(.conservative)),
             (.stability(.conservative), .stability(.full)):
            return "Contradictory stability settings"

        default:
            return nil
        }
    }

    // MARK: - Known Intents (for suggestions)

    static let allKnownIntents: [ScheduleIntent] = [
        // Triggers
        .onEventDeleted, .onNewEvent, .daily(hour: 9), .weekly(day: 2), .onCalendarSync,
        // Sources
        .fromCalendar(name: "Work"), .fromProject(name: ""),
        // Context
        .noEventsBefore(hour: 11), .noEventsAfter(hour: 17),
        .horizon(.today), .horizon(.tomorrow), .horizon(.week),
        // Tasks
        .includeBacklog, .findSlotsForBacklog,
        // Create
        .focusBlock(minutes: 120), .pomodoroSession,
        // Transforms
        .splitLong(maxMinutes: 90), .addBuffer(minutes: 10),
        .capTotal(minutesPerDay: 360),
        // Weights
        .prioritizeDeadlines(), .prioritizeFocus(),
        .minimizeContextSwitching(), .groupByProject(), .batchMeetings(),
        // Energy
        .lowEnergy, .morningPerson, .protectLunch(),
        .breakEvery(workMinutes: 60, breakMinutes: 10),
        .maxMeetings(perDay: 3),
        // Rules
        .stability(.normal), .stability(.conservative),
        // Config
        .speed(.quick), .speed(.balanced), .speed(.thorough),
        // Smart scheduling
        .contingencyBuffer(percent: 20),
        .focusProtection(bufferMinutes: 15),
        .meetingPrep(minutes: 10),
        .windDown(lastHours: 2),
        .taskOrder(.hardestFirst), .taskOrder(.shortestFirst), .taskOrder(.urgentFirst),
        .minGap(minutes: 10),
        .matchEnergyCurve,
        .warmUp(minutes: 15), .coolDown(minutes: 10),
        .travelBuffer(minutes: 15),
        .endOfDayReview(minutes: 15),
        .timeBox(maxMinutes: 90),
        .halfDay(.morningOnly), .halfDay(.afternoonOnly),
        .likeYesterday,
        // Social
        .officeHours(start: 14, end: 16),
        .noOverlap,
        // Health
        .microBreak(everyMinutes: 60, durationMinutes: 5),
        .walkBreak(afterMinutes: 90, durationMinutes: 10),
        .noScreensAfter(hour: 20),
        // Context
        .deepShallowSplit(deepPeriod: .morning, shallowPeriod: .afternoon),
        .groupByLocation,
        // Adaptive
        .stretchGoals(maxExtra: 2),
        .overflowToTomorrow,
        .energyCheckIn(atHour: 14),
        .skipWeekends,
        // Output
        .autoApply, .saveAsPreset(name: ""),
    ]
}
