import Foundation

// MARK: - Suggestion Engine

/// Composes smart optimization requests from schedule context.
/// The user never sees 65 intents — this engine picks the right ones
/// and composes a request that just works.
///
/// Birman: "Пусть потеет машина" — the system does the thinking.
@MainActor
@Observable
final class SuggestionEngine {

    let reminderService: ReminderService
    let backlogService: BacklogService

    /// The single best suggestion right now (for SmartBanner).
    var suggestion: Suggestion?

    nonisolated(unsafe) private var suggestionTimer: Timer?

    init(reminderService: ReminderService, backlogService: BacklogService) {
        self.reminderService = reminderService
        self.backlogService = backlogService
        startSuggestionTimer()
    }

    struct Suggestion: Sendable {
        let request: OptimizationRequest
        let reason: String
    }

    // MARK: - Evaluate

    func evaluate() {
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let events = reminderService.allEvents
        let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let todayEvents = events.filter { $0.startDate >= now && $0.startDate < todayEnd }
        let meetings = todayEvents.filter { !$0.isLocalEvent }
        let pending = backlogService.pending
        let urgent = backlogService.urgent(withinDays: 2)
        let overdue = backlogService.overdue

        // Compose a request from ALL signals at once — not picking a preset
        var intents: [ScheduleIntent] = [.horizon(.today)]
        var reason = ""

        // Priority cascade: most urgent situation wins
        if !overdue.isEmpty {
            intents.append(contentsOf: [.includeBacklog, .findSlotsForBacklog, .speed(.quick), .scenarios(count: 1)])
            reason = "\(overdue.count) overdue task\(overdue.count == 1 ? "" : "s")"
        } else if !urgent.isEmpty {
            intents.append(contentsOf: [.includeBacklog, .prioritizeDeadlines(weight: 3.0), .speed(.balanced), .scenarios(count: 2)])
            reason = "\(urgent.first!.title) due soon"
        } else if meetings.count >= 5 && !pending.isEmpty {
            intents.append(contentsOf: [.batchMeetings(), .includeBacklog, .protectLunch(), .speed(.balanced), .scenarios(count: 2)])
            reason = "\(meetings.count) meetings + \(pending.count) tasks"
        } else if meetings.count >= 5 {
            intents.append(contentsOf: [.batchMeetings(), .protectLunch(), .speed(.quick), .scenarios(count: 1)])
            reason = "\(meetings.count) meetings — batch them?"
        } else if pending.count >= 3 {
            intents.append(contentsOf: [.includeBacklog, .findSlotsForBacklog, .speed(.quick), .scenarios(count: 1)])
            reason = "\(pending.count) tasks to schedule"
        } else if hour < 14 && !todayEvents.contains(where: { $0.eventType == .pomodoro }) {
            intents.append(contentsOf: [.focusBlock(minutes: 120, period: .morning), .findSlotsForBacklog, .speed(.quick), .scenarios(count: 1)])
            reason = "No focus time today"
        } else if hour < 10 && todayEvents.count >= 3 {
            intents.append(contentsOf: [.includeBacklog, .speed(.balanced), .scenarios(count: 2)])
            reason = "Organize your day"
        } else {
            suggestion = nil
            return
        }

        // Layer in time-aware intents automatically
        if hour >= 14 { intents.append(.protectLunch()) }
        if hour >= 16 { intents.append(.windDown(lastHours: 2)) }
        if meetings.count >= 3 { intents.append(.meetingPrep(minutes: 5)) }

        suggestion = Suggestion(
            request: OptimizationRequest(intents, name: reason),
            reason: reason
        )
    }

    // MARK: - Timer

    private func startSuggestionTimer() {
        evaluate()
        suggestionTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
    }

    deinit { suggestionTimer?.invalidate() }
}
