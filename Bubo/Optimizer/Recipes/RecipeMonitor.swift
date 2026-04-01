import Foundation

// MARK: - Recipe Monitor

/// Watches for schedule changes and auto-executes reaction recipes.
/// Also evaluates recipe conditions for contextual suggestions.
@MainActor
@Observable
final class RecipeMonitor {

    let optimizer: BuboOptimizer
    let reminderService: ReminderService

    /// Currently suggested recipes based on conditions.
    private(set) var suggestedRecipes: [ScheduleRecipe] = []

    /// Last reaction result (for UI display).
    private(set) var lastReaction: RecipeResult?
    private(set) var lastReactionRecipe: ScheduleRecipe?

    /// Active reaction recipes.
    var reactions: [ScheduleRecipe] = RecipeCatalog.reactions

    /// Whether autopilot mode is enabled.
    var autopilotEnabled: Bool = false {
        didSet {
            if autopilotEnabled {
                startPeriodicChecks()
            } else {
                stopPeriodicChecks()
            }
        }
    }

    private var periodicTimer: Timer?

    init(optimizer: BuboOptimizer, reminderService: ReminderService) {
        self.optimizer = optimizer
        self.reminderService = reminderService
    }

    // MARK: - Event Change Handling

    enum EventChange {
        case deleted(eventId: String)
        case moved(eventId: String)
        case created(eventId: String)
        case periodic
    }

    /// Called by the app when schedule events change.
    func onEventChange(_ change: EventChange, workingHours: ClosedRange<Int>) async {
        let matchingRecipes = reactions.filter { recipe in
            switch (recipe.trigger, change) {
            case (.eventDeleted, .deleted): return true
            case (.eventMoved, .moved): return true
            case (.eventCreated, .created): return true
            case (.periodic, .periodic): return true
            default: return false
            }
        }

        for recipe in matchingRecipes {
            let executor = RecipeExecutor(optimizer: optimizer, reminderService: reminderService)
            let result = await executor.execute(recipe, defaultWorkingHours: workingHours)

            if let optimizerResult = result.optimizerResult,
               let best = optimizerResult.scenarios.first,
               best.fitness > (optimizer.lastResult?.scenarios.first?.fitness ?? 0) + optimizer.reoptimizer.minimumImprovement {
                lastReaction = result
                lastReactionRecipe = recipe
            }
        }
    }

    // MARK: - Condition Evaluation

    /// Evaluate all recipe conditions against current schedule state.
    /// Returns recipes that match the current context.
    func evaluateSuggestions() {
        let allRecipes = RecipeCatalog.allCategories.flatMap(\.recipes)
        suggestedRecipes = allRecipes.filter { recipe in
            guard !recipe.conditions.isEmpty else { return false }
            return recipe.conditions.allSatisfy { condition in
                evaluate(condition)
            }
        }
    }

    private func evaluate(_ condition: RecipeCondition) -> Bool {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart)!

        let todayEvents = reminderService.allEvents.filter {
            $0.startDate >= todayStart && $0.startDate < todayEnd
        }

        switch condition {
        case .minEvents(let min):
            return todayEvents.count >= min

        case .maxEvents(let max):
            return todayEvents.count <= max

        case .hasFocusBlocks:
            return todayEvents.contains { $0.eventType == .pomodoro || $0.title.localizedCaseInsensitiveContains("focus") }

        case .noFocusBlocks:
            return !todayEvents.contains { $0.eventType == .pomodoro || $0.title.localizedCaseInsensitiveContains("focus") }

        case .hasDeadlineWithin(let days):
            let deadline = cal.date(byAdding: .day, value: days, to: now)!
            return reminderService.localEvents.contains { event in
                // Check if any local event has an upcoming deadline
                event.endDate <= deadline && event.endDate > now
            }

        case .meetingHeavy(let threshold):
            let meetingCount = todayEvents.filter { $0.meetingLink != nil || $0.calendarName != nil }.count
            return meetingCount >= threshold

        case .dayOfWeek(let weekday):
            return cal.component(.weekday, from: now) == weekday

        case .hasGapLongerThan(let minutes):
            let sortedEvents = todayEvents.sorted { $0.startDate < $1.startDate }
            var cursor = now
            for event in sortedEvents {
                if event.startDate.timeIntervalSince(cursor) >= TimeInterval(minutes * 60) {
                    return true
                }
                cursor = max(cursor, event.endDate)
            }
            return todayEnd.timeIntervalSince(cursor) >= TimeInterval(minutes * 60)

        case .afterHour(let hour):
            return cal.component(.hour, from: now) >= hour

        case .hasContext(let ctx):
            return todayEvents.contains { $0.calendarName == ctx }
        }
    }

    // MARK: - Periodic Checks

    private func startPeriodicChecks() {
        stopPeriodicChecks()
        // Check every 30 minutes when autopilot is active
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Re-evaluate suggestions
                self.evaluateSuggestions()
            }
        }
    }

    private func stopPeriodicChecks() {
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    // MARK: - Clear

    func clearLastReaction() {
        lastReaction = nil
        lastReactionRecipe = nil
    }
}
