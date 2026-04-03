import Foundation

// MARK: - Optimizer Service

/// Bridges BuboOptimizer with ReminderService and the rest of the app.
/// All optimization calls are async to avoid blocking the main thread.
@MainActor
@Observable
final class OptimizerService {

    let optimizer = BuboOptimizer()
    let usageTracker = RecipeUsageTracker()

    var scenarios: [ScheduleScenario] = []
    private(set) var selectedScenarioIndex: Int? = nil
    private(set) var isOptimizing: Bool = false
    private(set) var lastOptimizationDate: Date? = nil
    private(set) var error: String? = nil

    /// The last applied recipe snapshot for undo support.
    private(set) var lastSnapshot: AppliedRecipeSnapshot? = nil

    /// The recipe that produced the current scenarios.
    var activeRecipe: ScheduleRecipe? = nil

    /// Recipe monitor for auto-triggered reactions and contextual suggestions.
    private(set) var recipeMonitor: RecipeMonitor? = nil

    // MARK: - Optimizer Settings (persisted)

    var workingHoursStart: Int {
        didSet {
            // Ensure start < end to prevent zero-duration range
            if workingHoursStart >= workingHoursEnd {
                workingHoursEnd = workingHoursStart + 1
            }
            saveSettings()
        }
    }
    var workingHoursEnd: Int {
        didSet {
            // Ensure start < end to prevent zero-duration range
            if workingHoursEnd <= workingHoursStart {
                workingHoursStart = workingHoursEnd - 1
            }
            saveSettings()
        }
    }

    private let persistenceKey = "BuboOptimizerServiceSettings"
    private let preferencesKey = "BuboOptimizerPreferences"

    init() {
        let saved = Self.loadSettings()
        self.workingHoursStart = saved.start
        self.workingHoursEnd = saved.end
        // Restore optimizer preferences
        if let data = UserDefaults.standard.data(forKey: "BuboOptimizerPreferences"),
           let prefs = try? JSONDecoder().decode(OptimizerPreferences.self, from: data) {
            self.optimizer.preferences = prefs
        }
    }

    var workingHours: ClosedRange<Int> {
        workingHoursStart...workingHoursEnd
    }

    // MARK: - Optimize Day

    func optimizeDay(
        reminderService: ReminderService,
        movableTasks: [OptimizableEvent]
    ) async {
        isOptimizing = true
        defer { isOptimizing = false }
        error = nil

        let fixedEvents = reminderService.allEvents.filter { !$0.isLocalEvent }

        let result = await optimizer.optimizeToday(
            fixedEvents: fixedEvents,
            movableEvents: movableTasks,
            workingHours: workingHours
        )

        scenarios = result.scenarios
        selectedScenarioIndex = scenarios.isEmpty ? nil : 0
        lastOptimizationDate = Date()
    }

    // MARK: - Optimize Week

    func optimizeWeek(
        reminderService: ReminderService,
        movableTasks: [OptimizableEvent],
        participantAvailability: [String: [DateInterval]] = [:]
    ) async {
        isOptimizing = true
        defer { isOptimizing = false }
        error = nil

        let fixedEvents = reminderService.allEvents.filter { !$0.isLocalEvent }

        let result = await optimizer.optimizeWeek(
            fixedEvents: fixedEvents,
            movableEvents: movableTasks,
            workingHours: workingHours,
            participantAvailability: participantAvailability
        )

        scenarios = result.scenarios
        selectedScenarioIndex = scenarios.isEmpty ? nil : 0
        lastOptimizationDate = Date()
    }

    // MARK: - Suggest Focus Blocks

    func suggestFocusBlocks(
        count: Int = 2,
        durationMinutes: Int = 120,
        reminderService: ReminderService
    ) async {
        isOptimizing = true
        defer { isOptimizing = false }
        error = nil

        let fixedEvents = reminderService.allEvents.filter { !$0.isLocalEvent }

        let result = await optimizer.suggestFocusBlocks(
            count: count,
            durationMinutes: durationMinutes,
            fixedEvents: fixedEvents,
            workingHours: workingHours
        )

        scenarios = result.scenarios
        selectedScenarioIndex = scenarios.isEmpty ? nil : 0
        lastOptimizationDate = Date()
    }

    // MARK: - Suggest Pomodoro Slot

    func suggestPomodoroSlot(
        config: PomodoroConfig = .classic,
        reminderService: ReminderService
    ) async {
        isOptimizing = true
        defer { isOptimizing = false }
        error = nil

        let fixedEvents = reminderService.allEvents.filter { !$0.isLocalEvent }

        let result = await optimizer.suggestPomodoroSlot(
            config: config,
            fixedEvents: fixedEvents,
            workingHours: workingHours
        )

        scenarios = result.scenarios
        selectedScenarioIndex = scenarios.isEmpty ? nil : 0
        lastOptimizationDate = Date()
    }

    // MARK: - Apply Scenario

    func applyScenario(at index: Int, to reminderService: ReminderService, titleOverride: String? = nil, colorOverride: EventColorTag? = nil) {
        guard index < scenarios.count else { return }
        let scenario = scenarios[index]

        optimizer.acceptScenario(scenario)

        for (i, gene) in scenario.genes.enumerated() {
            let title: String
            if let override = titleOverride, !override.isEmpty {
                title = scenario.genes.count > 1 ? "\(override) \(i + 1)" : override
            } else {
                title = gene.title
            }
            let event = CalendarEvent(
                id: gene.eventId,
                title: title,
                startDate: gene.startTime,
                endDate: gene.endTime,
                location: nil,
                description: "Created by Schedule Assistant",
                calendarName: nil,
                eventType: gene.isFocusBlock ? .pomodoro : .standard,
                colorTag: colorOverride ?? (gene.isFocusBlock ? .blue : .green)
            )
            reminderService.addLocalEvent(event)
        }

        selectedScenarioIndex = index
    }

    func rejectScenario(at index: Int) {
        guard index < scenarios.count else { return }
        optimizer.rejectScenario(scenarios[index])
    }

    // MARK: - Scenario Info

    var selectedScenario: ScheduleScenario? {
        guard let idx = selectedScenarioIndex, idx < scenarios.count else { return nil }
        return scenarios[idx]
    }

    var comparisons: [ScenarioComparison] {
        optimizer.compareLastScenarios()
    }

    // MARK: - Persistence

    private struct SavedSettings: Codable {
        let start: Int
        let end: Int
    }

    private func saveSettings() {
        let saved = SavedSettings(start: workingHoursStart, end: workingHoursEnd)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }

    /// Persist optimizer preferences (called from OptimizerTabView on changes).
    func savePreferences() {
        if let data = try? JSONEncoder().encode(optimizer.preferences) {
            UserDefaults.standard.set(data, forKey: preferencesKey)
        }
    }

    private static func loadSettings() -> (start: Int, end: Int) {
        guard let data = UserDefaults.standard.data(forKey: "BuboOptimizerServiceSettings"),
              let saved = try? JSONDecoder().decode(SavedSettings.self, from: data) else {
            return (start: 9, end: 18)
        }
        return (start: saved.start, end: saved.end)
    }

    func reset() {
        optimizer.reset()
        scenarios = []
        selectedScenarioIndex = nil
        error = nil
        activeRecipe = nil
        lastSnapshot = nil
    }

    // MARK: - Recipe Execution

    /// Execute a ScheduleRecipe — the universal entry point for all optimization flows.
    func executeRecipe(
        _ recipe: ScheduleRecipe,
        paramValues: [String: Any] = [:],
        reminderService: ReminderService
    ) async -> RecipeResult {
        isOptimizing = true
        defer { isOptimizing = false }
        error = nil
        activeRecipe = recipe

        let executor = RecipeExecutor(optimizer: optimizer, reminderService: reminderService)
        let result = await executor.execute(recipe, paramValues: paramValues, defaultWorkingHours: workingHours)

        switch result {
        case .success(let optimizerResult):
            scenarios = optimizerResult.scenarios
            selectedScenarioIndex = scenarios.isEmpty ? nil : 0
            lastOptimizationDate = Date()
            usageTracker.recordExecution(recipeId: recipe.id)

        case .partialSuccess(let optimizerResult, let warnings):
            scenarios = optimizerResult.scenarios
            selectedScenarioIndex = scenarios.isEmpty ? nil : 0
            lastOptimizationDate = Date()
            error = warnings.first
            if !optimizerResult.scenarios.isEmpty {
                usageTracker.recordExecution(recipeId: recipe.id)
            }

        case .noEventsToOptimize:
            error = "No events to optimize"

        case .infeasible(let reason, _):
            error = reason
        }

        return result
    }

    /// Apply the selected scenario and record feedback for learning.
    func applyRecipeScenario(
        at index: Int,
        to reminderService: ReminderService,
        titleOverride: String? = nil,
        colorOverride: EventColorTag? = nil
    ) {
        guard index < scenarios.count else { return }
        let scenario = scenarios[index]

        // Record snapshot for undo
        let previousGenes = optimizer.currentSchedule
        var createdEventIds: [String] = []

        // Apply scenario (same as existing applyScenario)
        optimizer.acceptScenario(scenario)

        for (i, gene) in scenario.genes.enumerated() {
            let title: String
            if let override = titleOverride, !override.isEmpty {
                title = scenario.genes.count > 1 ? "\(override) \(i + 1)" : override
            } else {
                title = gene.title
            }
            let event = CalendarEvent(
                id: gene.eventId,
                title: title,
                startDate: gene.startTime,
                endDate: gene.endTime,
                location: nil,
                description: "Created by Schedule Assistant",
                calendarName: nil,
                eventType: gene.isFocusBlock ? .pomodoro : .standard,
                colorTag: colorOverride ?? (gene.isFocusBlock ? .blue : .green)
            )
            reminderService.addLocalEvent(event)
            createdEventIds.append(event.id)
        }

        // Record acceptance for HN ranking
        if let recipeId = activeRecipe?.id {
            usageTracker.recordAcceptance(recipeId: recipeId)
        }

        // Save undo snapshot
        lastSnapshot = AppliedRecipeSnapshot(
            recipeId: activeRecipe?.id ?? "",
            appliedAt: Date(),
            previousGenes: previousGenes,
            appliedGenes: scenario.genes,
            createdEventIds: createdEventIds
        )

        selectedScenarioIndex = index
    }

    /// Undo the last applied recipe by removing created events.
    func undoLastRecipe(reminderService: ReminderService) {
        guard let snapshot = lastSnapshot else { return }
        for eventId in snapshot.createdEventIds {
            reminderService.removeLocalEvent(id: eventId)
        }
        optimizer.currentSchedule = snapshot.previousGenes
        lastSnapshot = nil
        scenarios = []
        selectedScenarioIndex = nil
    }

    /// Initialize the recipe monitor (called once when reminderService is available).
    func setupRecipeMonitor(reminderService: ReminderService) {
        recipeMonitor = RecipeMonitor(optimizer: optimizer, reminderService: reminderService)
        recipeMonitor?.evaluateSuggestions()
    }
}
