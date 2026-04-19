import Foundation

// MARK: - Intent Presets

/// Named optimization presets that replace the 50+ recipe catalog.
/// Each preset is just a named array of composable intents.
/// Users can pick a preset and add/remove intents before running.
struct IntentPresets {

    // MARK: - Stable preset names
    //
    // Display-name strings used elsewhere as `seedRecipeId` to pre-select a
    // preset in the Command Palette. Centralised here so callers (e.g.
    // `MenuBarView` after a Pomodoro timer finishes) can't drift out of sync
    // with the preset's actual `name:`. Birman: одно место правды для строк.
    enum Name {
        static let pomodoroSession = "Pomodoro session"
        static let focusBurst = "Focus burst"
    }

    // MARK: - Quick Actions (shown prominently in palette)

    static let quickActions: [OptimizationRequest] = [
        .organizeDay,
        .findFocus(),
        .pomodoroBlock,
        .focusBurstBlock(),
        .deadlineMode,
        .planWeek,
        .lowEnergyDay,
        .scheduleBacklog,
    ]

    // MARK: - All Presets

    struct Category: Identifiable {
        let id: String
        let name: String
        let presets: [OptimizationRequest]
    }

    static let allCategories: [Category] = [
        Category(id: "planning", name: "Planning", presets: [
            .organizeDay,
            .planWeek,
            .scheduleBacklog,
        ]),
        Category(id: "focus", name: "Focus", presets: [
            .findFocus(),
            .deepWork(),
            .pomodoroBlock,
            .focusBurstBlock(),
        ]),
        Category(id: "deadlines", name: "Deadlines", presets: [
            .deadlineMode,
            .deadlineCrunch,
        ]),
        Category(id: "meetings", name: "Meetings", presets: [
            .batchMeetingsPreset,
            .meetingBuffer(),
        ]),
        Category(id: "energy", name: "Energy", presets: [
            .lowEnergyDay,
            .morningPersonPreset,
        ]),
        Category(id: "adjust", name: "Adjustments", presets: [
            .lateStart(),
            .shortDay(),
        ]),
    ]

    /// All presets in a flat list for search.
    static var all: [OptimizationRequest] {
        allCategories.flatMap(\.presets)
    }

    // MARK: - Reaction Presets (auto-triggered)

    static let onEventDeleted = OptimizationRequest(
        .horizon(.today), .stability(.normal), .speed(.quick), .scenarios(count: 1),
        name: "Rebalance after deletion"
    )

    static let onEventMoved = OptimizationRequest(
        .horizon(.today), .stability(.conservative), .speed(.quick), .scenarios(count: 1),
        name: "Adjust after move"
    )
}

// MARK: - Preset Definitions

extension OptimizationRequest {

    // MARK: - Planning

    static let organizeDay = OptimizationRequest(
        .horizon(.today), .stability(.normal), .speed(.balanced),
        .includeBacklog, .scenarios(count: 3),
        name: "Organize day"
    )

    static let planWeek = OptimizationRequest(
        .horizon(.week), .stability(.normal), .speed(.thorough),
        .includeBacklog, .scenarios(count: 3),
        name: "Plan week"
    )

    static let scheduleBacklog = OptimizationRequest(
        .horizon(.today), .findSlotsForBacklog, .speed(.quick),
        .scenarios(count: 1),
        name: "Schedule tasks"
    )

    // MARK: - Focus

    static func findFocus(minutes: Int = 120, period: Period? = .morning) -> OptimizationRequest {
        OptimizationRequest(
            .focusBlock(minutes: minutes, period: period),
            .horizon(.today), .findSlotsForBacklog,
            .prioritizeFocus(), .speed(.quick), .scenarios(count: 1),
            name: "Find focus time"
        )
    }

    static func deepWork(minutes: Int = 180) -> OptimizationRequest {
        OptimizationRequest(
            .focusBlock(minutes: minutes, period: .morning),
            .horizon(.today), .findSlotsForBacklog,
            .prioritizeFocus(weight: 2.5), .minimizeContextSwitching(),
            .speed(.balanced), .scenarios(count: 1),
            name: "Deep work block"
        )
    }

    static let pomodoroBlock = OptimizationRequest(
        .pomodoroSession,
        .horizon(.today), .findSlotsForBacklog,
        .speed(.quick), .scenarios(count: 1),
        // Stable name constant — see IntentPresets.Name. Keeps the
        // post-Pomodoro `seedRecipeId` lookup in MenuBarView in sync.
        name: IntentPresets.Name.pomodoroSession
    )

    /// Pack up to N related backlog tasks into one pomodoro: each work
    /// round hosts a different task, breaks sit between them, and the
    /// timer labels each round with the current task's name.
    static func focusBurstBlock(maxTasks: Int = 4, contextFilter: String? = nil) -> OptimizationRequest {
        OptimizationRequest(
            .focusBurst(maxTasks: maxTasks, contextFilter: contextFilter),
            .horizon(.today), .findSlotsForBacklog,
            .minimizeContextSwitching(weight: 2.0),
            .speed(.quick), .scenarios(count: 1),
            name: IntentPresets.Name.focusBurst
        )
    }

    // MARK: - Deadlines

    static let deadlineMode = OptimizationRequest(
        .horizon(.today), .prioritizeDeadlines(weight: 3.0),
        .stability(.full), .speed(.balanced), .scenarios(count: 2),
        name: "Deadline mode"
    )

    static let deadlineCrunch = OptimizationRequest(
        .horizon(.today), .prioritizeDeadlines(weight: 5.0),
        .stability(.full), .speed(.thorough),
        .maxMeetings(perDay: 2), .scenarios(count: 1),
        name: "Deadline crunch"
    )

    // MARK: - Meetings

    static let batchMeetingsPreset = OptimizationRequest(
        .horizon(.today), .batchMeetings(weight: 2.0),
        .stability(.normal), .speed(.balanced), .scenarios(count: 2),
        name: "Batch meetings"
    )

    static func meetingBuffer(minutes: Int = 15) -> OptimizationRequest {
        OptimizationRequest(
            .horizon(.today), .breakEvery(workMinutes: 60, breakMinutes: minutes),
            .batchMeetings(), .stability(.conservative),
            .speed(.quick), .scenarios(count: 1),
            name: "Buffer between meetings"
        )
    }

    // MARK: - Energy

    static let lowEnergyDay = OptimizationRequest(
        .horizon(.today), .lowEnergy,
        .breakEvery(workMinutes: 45, breakMinutes: 15),
        .maxMeetings(perDay: 3), .protectLunch(),
        .stability(.normal), .speed(.balanced), .scenarios(count: 2),
        name: "Low energy day"
    )

    static let morningPersonPreset = OptimizationRequest(
        .horizon(.today), .morningPerson,
        .peakEnergy(hour: 9), .stability(.normal),
        .speed(.balanced), .scenarios(count: 2),
        name: "Morning person"
    )

    // MARK: - Adjustments

    static func lateStart(hour: Int = 11) -> OptimizationRequest {
        OptimizationRequest(
            .noEventsBefore(hour: hour), .horizon(.today),
            .stability(.conservative), .speed(.quick), .scenarios(count: 1),
            name: "Late start (\(hour):00)"
        )
    }

    static func shortDay(endHour: Int = 15) -> OptimizationRequest {
        OptimizationRequest(
            .noEventsAfter(hour: endHour), .horizon(.today),
            .stability(.conservative), .speed(.quick), .scenarios(count: 1),
            name: "Short day (until \(endHour):00)"
        )
    }
}
