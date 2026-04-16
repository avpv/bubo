import Foundation
import UserNotifications

// MARK: - Trigger Engine

/// Executes optimization requests based on trigger nodes.
/// Manages scheduled triggers (.daily, .weekly) and reactive triggers
/// (.onEventDeleted, .onNewEvent, .onCalendarSync).
///
/// The engine scans OptimizationRequests stored in the SubgraphRegistry
/// for trigger intents and executes them when conditions are met.
@MainActor
@Observable
final class TriggerEngine {

    let optimizerService: OptimizerService
    let reminderService: ReminderService

    nonisolated(unsafe) private var dailyTimers: [String: Timer] = [:]
    nonisolated(unsafe) private var weeklyTimers: [String: Timer] = [:]
    private(set) var lastTriggeredAt: Date?
    private(set) var lastTriggeredName: String?

    init(optimizerService: OptimizerService, reminderService: ReminderService) {
        self.optimizerService = optimizerService
        self.reminderService = reminderService
    }

    // MARK: - Start/Stop

    /// Scan all saved pipelines for triggers and schedule them.
    func startAll() {
        guard let registry = optimizerService.subgraphRegistry else { return }

        stopAll()

        for sg in registry.subgraphs.values {
            for intent in sg.intents {
                switch intent {
                case .daily(let hour):
                    scheduleDaily(subgraph: sg, hour: hour, registry: registry)
                case .weekly(let day):
                    scheduleWeekly(subgraph: sg, day: day, registry: registry)
                default:
                    break
                }
            }
        }
    }

    func stopAll() {
        dailyTimers.values.forEach { $0.invalidate() }
        weeklyTimers.values.forEach { $0.invalidate() }
        dailyTimers.removeAll()
        weeklyTimers.removeAll()
    }

    // MARK: - Reactive Triggers

    /// Called when an event is deleted. Finds and executes matching triggers.
    func onEventDeleted(eventId: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Free slot!"
        content.body = "Meeting was cancelled. Start a sprint session?"
        content.sound = .default
        let req = UNNotificationRequest(identifier: "Opportunity-\(eventId)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)

        await executeTrigger(.onEventDeleted, context: "Event \(eventId) deleted")
    }

    /// Called when a new event is created.
    func onNewEvent(eventId: String) async {
        await executeTrigger(.onNewEvent, context: "Event \(eventId) created")
    }

    /// Called after Apple Calendar sync completes.
    func onCalendarSync() async {
        await executeTrigger(.onCalendarSync, context: "Calendar synced")
    }

    // MARK: - Scheduled Triggers

    private func scheduleDaily(subgraph: Subgraph, hour: Int, registry: SubgraphRegistry) {
        let cal = Calendar.current
        let now = Date()

        // Find next occurrence of this hour
        var nextFire: Date
        if let today = cal.date(bySettingHour: hour, minute: 0, second: 0, of: now),
           today > now {
            nextFire = today
        } else {
            let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
            nextFire = cal.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }

        let interval = nextFire.timeIntervalSince(now)
        let timerId = "daily-\(subgraph.id)"

        // Fire once at the target time, then repeat every 24h
        dailyTimers[timerId] = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.executeSubgraph(subgraph, registry: registry, context: "Daily at \(hour):00")

                // Schedule repeating timer for subsequent days
                self.dailyTimers[timerId] = Timer.scheduledTimer(
                    withTimeInterval: 86400, // 24h
                    repeats: true
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.executeSubgraph(subgraph, registry: registry, context: "Daily at \(hour):00")
                    }
                }
            }
        }
    }

    private func scheduleWeekly(subgraph: Subgraph, day: Int, registry: SubgraphRegistry) {
        let cal = Calendar.current
        let now = Date()

        // Find next occurrence of this day of week
        var search = now
        for _ in 0..<8 {
            if cal.component(.weekday, from: search) == day && search > now {
                break
            }
            search = cal.date(byAdding: .day, value: 1, to: search)!
        }

        // Default to 9:00 for weekly triggers
        let nextFire = cal.date(bySettingHour: 9, minute: 0, second: 0, of: search) ?? search
        let interval = max(1, nextFire.timeIntervalSince(now))
        let timerId = "weekly-\(subgraph.id)"

        weeklyTimers[timerId] = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.executeSubgraph(subgraph, registry: registry, context: "Weekly")

                // Repeat every 7 days
                self.weeklyTimers[timerId] = Timer.scheduledTimer(
                    withTimeInterval: 604800, // 7 days
                    repeats: true
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.executeSubgraph(subgraph, registry: registry, context: "Weekly")
                    }
                }
            }
        }
    }

    // MARK: - Execution

    /// Execute all pipelines that contain the given trigger.
    private func executeTrigger(_ trigger: ScheduleIntent, context: String) async {
        guard let registry = optimizerService.subgraphRegistry else { return }

        for sg in registry.subgraphs.values {
            if sg.intents.contains(trigger) {
                await executeSubgraph(sg, registry: registry, context: context)
            }
        }
    }

    /// Execute a subgraph as an optimization request.
    private func executeSubgraph(_ subgraph: Subgraph, registry: SubgraphRegistry, context: String) async {
        let request = OptimizationRequest.fromSubgraph(subgraph, registry: registry)

        // Check if autoApply is set
        let shouldAutoApply = request.intents.contains {
            if case .autoApply = $0 { return true }
            return false
        }

        let result = await optimizerService.executeRequest(request, reminderService: reminderService)

        if shouldAutoApply {
            if case .success = result, !optimizerService.scenarios.isEmpty {
                optimizerService.applyScenario(at: 0, to: reminderService)
            }
        }

        lastTriggeredAt = Date()
        lastTriggeredName = "\(subgraph.name) (\(context))"
    }

    deinit {
        dailyTimers.values.forEach { $0.invalidate() }
        weeklyTimers.values.forEach { $0.invalidate() }
    }
}
