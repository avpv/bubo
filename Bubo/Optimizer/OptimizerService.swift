import Foundation
import OSLog
import UserNotifications

// MARK: - Optimizer Service

/// Bridges BuboOptimizer with the rest of the app.
/// All optimization flows go through intent-based OptimizationRequest.
@MainActor
@Observable
final class OptimizerService {

    let optimizer = BuboOptimizer()
    let intentLearner = IntentLearner()

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

    /// The active optimization request (for display and learning).
    var activeRequestName: String? = nil
    /// The full active request (for IntentLearner recording).
    private var activeRequest: OptimizationRequest? = nil

    /// Backlog service for persistent task management.
    var backlogService: BacklogService?

    /// Subgraph registry for saved pipelines.
    private(set) var subgraphRegistry: SubgraphRegistry?

    /// Suggestion engine for contextual suggestions.
    private(set) var suggestionEngine: SuggestionEngine?

    /// Trigger engine for scheduled/reactive pipeline execution.
    private(set) var triggerEngine: TriggerEngine?

    /// Energy check-in service for adaptive energy curve.
    var energyCheckInService: EnergyCheckInService?

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

    /// Prevents didSet -> save -> push loop when reloading cloud data.
    private var isReloadingFromCloud = false
    private var cloudSyncObserver: Any?

    init() {
        let saved = Self.loadSettings()
        self.workingHoursStart = saved.start
        self.workingHoursEnd = saved.end
        if let data = UserDefaults.standard.data(forKey: "BuboOptimizerPreferences"),
           let prefs = try? JSONDecoder().decode(OptimizerPreferences.self, from: data) {
            self.optimizer.preferences = prefs
        }
        setupCloudSync()
    }

    private func setupCloudSync() {
        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: CloudSyncService.didReceiveRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let key = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.handleCloudSync(key: key)
            }
        }
    }

    private func handleCloudSync(key: String) {
        isReloadingFromCloud = true
        defer { isReloadingFromCloud = false }

        switch key {
        case persistenceKey:
            let saved = Self.loadSettings()
            workingHoursStart = saved.start
            workingHoursEnd = saved.end
        case preferencesKey:
            if let data = UserDefaults.standard.data(forKey: preferencesKey),
               let prefs = try? JSONDecoder().decode(OptimizerPreferences.self, from: data) {
                optimizer.preferences = prefs
            }
        default:
            break
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
        activeRequest = request

        var compiler = IntentCompiler(
            optimizer: optimizer,
            reminderService: reminderService,
            backlogService: backlogSvc
        )
        compiler.subgraphRegistry = subgraphRegistry
        compiler.energyCheckInService = energyCheckInService
        let result = await compiler.execute(request, defaultWorkingHours: workingHours)

        switch result {
        case .success(let optimizerResult):
            scenarios = optimizerResult.scenarios
            selectedScenarioIndex = scenarios.isEmpty ? nil : 0
            lastOptimizationDate = Date()

        case .partialSuccess(let optimizerResult, let warnings, _):
            scenarios = optimizerResult.scenarios
            selectedScenarioIndex = scenarios.isEmpty ? nil : 0
            lastOptimizationDate = Date()
            error = warnings.first

        case .noEventsToOptimize:
            error = "No events to optimize"

        case .infeasible(let reason, _, _):
            error = reason
        }

        return result
    }

    /// Instant reflow for drag-to-schedule and live preview.
    /// Ultra-fast GA (~100ms) with warm start from current schedule.
    func instantReflow(
        reminderService: ReminderService,
        movableEvents: [OptimizableEvent] = []
    ) async -> [ScheduleGene]? {
        let fixedEvents = reminderService.allEvents.filter { !$0.isLocalEvent }
        let localMovable = reminderService.localEvents
            .filter { $0.isUpcoming && $0.isMovable }
            .map { $0.toOptimizableEvent() }

        let allMovable = localMovable + movableEvents
        guard !allMovable.isEmpty else { return nil }

        let cal = Calendar.current
        let now = Date()
        let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!

        let context = OptimizerContext(
            fixedEvents: fixedEvents,
            movableEvents: allMovable,
            workingHours: workingHours,
            planningHorizon: DateInterval(start: now, end: todayEnd),
            preferences: optimizer.preferences
        )

        return await optimizer.instantReflow(context: context)
    }

    /// Dry-run for preview — returns genes without storing results.
    func executeDryRun(
        _ request: OptimizationRequest,
        reminderService: ReminderService
    ) async -> [ScheduleGene]? {
        guard let backlogSvc = backlogService else { return nil }
        var compiler = IntentCompiler(
            optimizer: optimizer,
            reminderService: reminderService,
            backlogService: backlogSvc
        )
        compiler.subgraphRegistry = subgraphRegistry
        compiler.energyCheckInService = energyCheckInService
        let result = await compiler.execute(request, defaultWorkingHours: workingHours)
        switch result {
        case .success(let r), .partialSuccess(let r, _, _):
            return r.scenarios.first?.genes
        default:
            return nil
        }
    }

    /// Week-Ahead Mock Simulator: proactively checks if all tasks fit in the week
    func runWeekMockSimulator(reminderService: ReminderService) async {
        guard let backlogSvc = backlogService else { return }
        var compiler = IntentCompiler(
            optimizer: optimizer,
            reminderService: reminderService,
            backlogService: backlogSvc
        )
        compiler.subgraphRegistry = subgraphRegistry
        compiler.energyCheckInService = energyCheckInService
        
        let req = OptimizationRequest(.horizon(.week), .includeBacklog)
        let result = await compiler.execute(req, defaultWorkingHours: workingHours)
        
        if case .partialSuccess(_, let warnings, _) = result {
            let endangered = warnings.filter { $0.lowercased().contains("task") || $0.lowercased().contains("planned") }
            if !endangered.isEmpty {
                let count = endangered.count
                let content = UNMutableNotificationContent()
                content.title = "Дедлайны под угрозой!"
                content.body = "Симулятор: задачи не укладываются в эту неделю. Разгрузить расписание?"
                content.sound = .default
                let request = UNNotificationRequest(identifier: "MockSimulator", content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
                _ = count
            }
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

        // Remove old calendar events for tasks being rescheduled
        for gene in scenario.activeGenes {
            if reminderService.localEvents.contains(where: { $0.id == gene.eventId }) {
                reminderService.removeLocalEvent(id: gene.eventId)
            }
        }

        for (i, gene) in scenario.activeGenes.enumerated() {
            let title: String
            if let override = titleOverride, !override.isEmpty {
                title = scenario.activeGenes.count > 1 ? "\(override) \(i + 1)" : override
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
            appliedGenes: scenario.activeGenes,
            createdEventIds: createdEventIds
        )

        freshlyCreatedEventIds = Set(createdEventIds)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            freshlyCreatedEventIds = []
        }

        selectedScenarioIndex = index

        // Record acceptance for intent learning
        if let request = activeRequest {
            intentLearner.recordExecution(request, outcome: .accepted)
        }
    }

    func rejectScenario(at index: Int) {
        guard index < scenarios.count else { return }
        optimizer.rejectScenario(scenarios[index])

        // Record rejection for intent learning
        if let request = activeRequest {
            intentLearner.recordExecution(request, outcome: .rejected)
        }
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
        self.subgraphRegistry = SubgraphRegistry()
        suggestionEngine = SuggestionEngine(
            reminderService: reminderService,
            backlogService: backlogService
        )
        suggestionEngine?.energyCheckInService = energyCheckInService

        // Scan saved pipelines for .energyCheckIn intents to configure prompt hours.
        if let registry = subgraphRegistry, let service = energyCheckInService {
            var hours: Set<Int> = []
            for sg in registry.subgraphs.values {
                for intent in sg.intents {
                    if case .energyCheckIn(let h) = intent {
                        hours.insert(h)
                    }
                }
            }
            if !hours.isEmpty {
                service.setPromptHours(Array(hours))
            }
        }

        triggerEngine = TriggerEngine(
            optimizerService: self,
            reminderService: reminderService
        )
        triggerEngine?.startAll()
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
        guard !isReloadingFromCloud else { return }
        let saved = SavedSettings(start: workingHoursStart, end: workingHoursEnd)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
            CloudSyncService.shared.push(persistenceKey)
        }
    }

    func savePreferences() {
        if let data = try? JSONEncoder().encode(optimizer.preferences) {
            UserDefaults.standard.set(data, forKey: preferencesKey)
            CloudSyncService.shared.push(preferencesKey)
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
