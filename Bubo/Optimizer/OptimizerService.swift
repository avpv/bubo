import Foundation

// MARK: - Optimizer Service

/// Bridges BuboOptimizer with the rest of the app.
/// All optimization flows go through intent-based OptimizationRequest.
@MainActor
@Observable
final class OptimizerService {

    let optimizer = BuboOptimizer()

    var scenarios: [ScheduleScenario] = []
    private(set) var selectedScenarioIndex: Int? = nil
    private(set) var isOptimizing: Bool = false
    private(set) var lastOptimizationDate: Date? = nil
    private(set) var error: String? = nil

    /// The last applied snapshot for undo support.
    private(set) var lastSnapshot: AppliedSnapshot? = nil

    /// IDs of events created in the most recent application.
    /// Used by EventRowView to highlight freshly created events.
    private(set) var freshlyCreatedEventIds: Set<String> = []

    /// The active optimization request name (for display).
    var activeRequestName: String? = nil

    /// Backlog service for persistent task management.
    var backlogService: BacklogService?

    /// Suggestion engine for contextual suggestions.
    private(set) var suggestionEngine: SuggestionEngine?

    // MARK: - Optimizer Settings (persisted)

    var workingHoursStart: Int {
        didSet {
            if workingHoursStart >= workingHoursEnd {
                workingHoursEnd = workingHoursStart + 1
            }
            saveSettings()
        }
    }
    var workingHoursEnd: Int {
        didSet {
            if workingHoursEnd <= workingHoursStart {
                workingHoursStart = workingHoursEnd - 1
            }
            saveSettings()
        }
    }

    var minSlotMinutes: Int {
        FreeSlotFinder.defaultMinSlotMinutes
    }

    private let persistenceKey = "BuboOptimizerServiceSettings"
    private let preferencesKey = "BuboOptimizerPreferences"

    init() {
        let saved = Self.loadSettings()
        self.workingHoursStart = saved.start
        self.workingHoursEnd = saved.end
        if let data = UserDefaults.standard.data(forKey: "BuboOptimizerPreferences"),
           let prefs = try? JSONDecoder().decode(OptimizerPreferences.self, from: data) {
            self.optimizer.preferences = prefs
        }
    }

    var workingHours: ClosedRange<Int> {
        workingHoursStart...workingHoursEnd
    }

    // MARK: - Execute Request (Primary Entry Point)

    /// Execute an OptimizationRequest (array of composable intents).
    func executeRequest(
        _ request: OptimizationRequest,
        reminderService: ReminderService
    ) async -> OptimizationResult {
        guard let backlogSvc = backlogService else {
            return .infeasible(reason: "Backlog service not initialized")
        }

        isOptimizing = true
        defer { isOptimizing = false }
        error = nil
        activeRequestName = request.name

        let compiler = IntentCompiler(
            optimizer: optimizer,
            reminderService: reminderService,
            backlogService: backlogSvc
        )
        let result = await compiler.execute(request, defaultWorkingHours: workingHours)

        switch result {
        case .success(let optimizerResult):
            scenarios = optimizerResult.scenarios
            selectedScenarioIndex = scenarios.isEmpty ? nil : 0
            lastOptimizationDate = Date()

        case .partialSuccess(let optimizerResult, let warnings):
            scenarios = optimizerResult.scenarios
            selectedScenarioIndex = scenarios.isEmpty ? nil : 0
            lastOptimizationDate = Date()
            error = warnings.first

        case .noEventsToOptimize:
            error = "No events to optimize"

        case .infeasible(let reason, _):
            error = reason
        }

        return result
    }

    /// Dry-run for preview — returns genes without storing results.
    func executeDryRun(
        _ request: OptimizationRequest,
        reminderService: ReminderService
    ) async -> [ScheduleGene]? {
        guard let backlogSvc = backlogService else { return nil }
        let compiler = IntentCompiler(
            optimizer: optimizer,
            reminderService: reminderService,
            backlogService: backlogSvc
        )
        let result = await compiler.execute(request, defaultWorkingHours: workingHours)
        switch result {
        case .success(let r), .partialSuccess(let r, _):
            return r.scenarios.first?.genes
        default:
            return nil
        }
    }

    // MARK: - Apply Scenario

    func applyScenario(
        at index: Int,
        to reminderService: ReminderService,
        titleOverride: String? = nil,
        colorOverride: EventColorTag? = nil
    ) {
        guard index < scenarios.count else { return }
        let scenario = scenarios[index]
        var createdEventIds: [String] = []
        let previousGenes = optimizer.currentSchedule

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

            // Link backlog tasks to their scheduled events
            backlogService?.markScheduled(
                id: gene.eventId,
                eventId: event.id,
                date: gene.startTime
            )
        }

        // Save undo snapshot
        lastSnapshot = AppliedSnapshot(
            requestName: activeRequestName ?? "",
            appliedAt: Date(),
            previousGenes: previousGenes,
            appliedGenes: scenario.genes,
            createdEventIds: createdEventIds
        )

        freshlyCreatedEventIds = Set(createdEventIds)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            freshlyCreatedEventIds = []
        }

        selectedScenarioIndex = index
    }

    func rejectScenario(at index: Int) {
        guard index < scenarios.count else { return }
        optimizer.rejectScenario(scenarios[index])
    }

    // MARK: - Undo

    func undoLast(reminderService: ReminderService) {
        guard let snapshot = lastSnapshot else { return }
        for eventId in snapshot.createdEventIds {
            reminderService.removeLocalEvent(id: eventId)
        }
        // Unschedule backlog tasks that were linked
        for gene in snapshot.appliedGenes {
            backlogService?.unschedule(id: gene.eventId)
        }
        optimizer.currentSchedule = snapshot.previousGenes
        lastSnapshot = nil
        scenarios = []
        selectedScenarioIndex = nil
    }

    // MARK: - Scenario Info

    var selectedScenario: ScheduleScenario? {
        guard let idx = selectedScenarioIndex, idx < scenarios.count else { return nil }
        return scenarios[idx]
    }

    var comparisons: [ScenarioComparison] {
        optimizer.compareLastScenarios()
    }

    // MARK: - Setup

    func setup(reminderService: ReminderService, backlogService: BacklogService) {
        self.backlogService = backlogService
        suggestionEngine = SuggestionEngine(
            reminderService: reminderService,
            backlogService: backlogService
        )
        // Auto carry-over unfinished tasks from previous days
        backlogService.carryOverUnfinished()
    }

    func reset() {
        optimizer.reset()
        scenarios = []
        selectedScenarioIndex = nil
        error = nil
        activeRequestName = nil
        lastSnapshot = nil
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
}
