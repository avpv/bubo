import Foundation

// MARK: - Suggestion Engine

/// Evaluates the current schedule context and composes
/// optimization requests dynamically based on what it observes.
///
/// Unlike the old RecipeMonitor which matched static conditions to preset recipes,
/// this engine analyzes schedule patterns and composes intents on the fly.
@MainActor
@Observable
final class SuggestionEngine {

    let reminderService: ReminderService
    let backlogService: BacklogService

    /// Currently suggested optimization request (shown in SmartBanner).
    /// Settable so the UI can dismiss it.
    var suggestion: Suggestion?

    private var suggestionTimer: Timer?

    init(reminderService: ReminderService, backlogService: BacklogService) {
        self.reminderService = reminderService
        self.backlogService = backlogService
        startSuggestionTimer()
    }

    struct Suggestion: Sendable {
        let request: OptimizationRequest
        let reason: String
        let priority: Int  // higher = more important
    }

    // MARK: - Evaluate

    func evaluate() {
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let events = reminderService.allEvents
        let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let todayEvents = events.filter { $0.startDate >= now && $0.startDate < todayEnd }

        // Collect all candidate suggestions and pick the highest priority
        var candidates: [Suggestion] = []

        // 1. Overdue backlog tasks
        let overdue = backlogService.overdue
        if !overdue.isEmpty {
            candidates.append(Suggestion(
                request: OptimizationRequest(
                    .includeBacklog, .findSlotsForBacklog,
                    .horizon(.today), .speed(.quick), .scenarios(count: 1),
                    name: "Schedule \(overdue.count) overdue task\(overdue.count == 1 ? "" : "s")"
                ),
                reason: "\(overdue.count) overdue task\(overdue.count == 1 ? "" : "s")",
                priority: 100
            ))
        }

        // 2. Urgent deadlines (within 2 days)
        let urgent = backlogService.urgent(withinDays: 2)
        if !urgent.isEmpty {
            let names = urgent.prefix(2).map(\.title).joined(separator: ", ")
            candidates.append(Suggestion(
                request: .deadlineMode,
                reason: "Due soon: \(names)",
                priority: 90
            ))
        }

        // 3. Many unscheduled tasks
        let pending = backlogService.pending
        if pending.count >= 3 {
            candidates.append(Suggestion(
                request: .scheduleBacklog,
                reason: "\(pending.count) tasks waiting",
                priority: 60
            ))
        }

        // 4. Meeting-heavy day (5+ meetings)
        let meetings = todayEvents.filter { !$0.isLocalEvent }
        if meetings.count >= 5 {
            candidates.append(Suggestion(
                request: .batchMeetingsPreset,
                reason: "\(meetings.count) meetings today",
                priority: 70
            ))
        }

        // 5. No focus time today (before 2pm)
        let hasFocus = todayEvents.contains { $0.eventType == .pomodoro || ($0.isLocalEvent && $0.duration >= 3600) }
        if !hasFocus && hour < 14 {
            candidates.append(Suggestion(
                request: .findFocus(),
                reason: "No focus time today",
                priority: 50
            ))
        }

        // 6. Long gap available (> 2 hours free)
        let sortedToday = todayEvents.sorted { $0.startDate < $1.startDate }
        var maxGap: TimeInterval = 0
        var cursor = now
        for event in sortedToday {
            let gap = event.startDate.timeIntervalSince(cursor)
            maxGap = max(maxGap, gap)
            cursor = max(cursor, event.endDate)
        }
        let remainingGap = todayEnd.timeIntervalSince(cursor)
        maxGap = max(maxGap, remainingGap)

        if maxGap > 7200 && !pending.isEmpty {  // > 2 hours and tasks exist
            let gapMinutes = Int(maxGap / 60)
            candidates.append(Suggestion(
                request: .scheduleBacklog,
                reason: "\(gapMinutes) min free — schedule tasks?",
                priority: 40
            ))
        }

        // 7. Morning — organize the day
        if hour < 10 && todayEvents.count >= 3 {
            candidates.append(Suggestion(
                request: .organizeDay,
                reason: "Start of day — organize?",
                priority: 30
            ))
        }

        // 8. High context switching (3+ consecutive different-project events)
        if detectHighContextSwitching(todayEvents) {
            candidates.append(Suggestion(
                request: OptimizationRequest(
                    .minimizeContextSwitching(weight: 2.0), .groupByProject(),
                    .horizon(.today), .stability(.normal), .speed(.balanced), .scenarios(count: 2),
                    name: "Reduce context switching"
                ),
                reason: "Many project switches today",
                priority: 55
            ))
        }

        // Pick the highest priority suggestion
        suggestion = candidates.max(by: { $0.priority < $1.priority })
    }

    // MARK: - Pattern Detection

    /// Detect if there are 3+ consecutive events from different projects.
    private func detectHighContextSwitching(_ events: [CalendarEvent]) -> Bool {
        let sorted = events.sorted { $0.startDate < $1.startDate }
        guard sorted.count >= 3 else { return false }

        var switchCount = 0
        for i in 1..<sorted.count {
            let prev = sorted[i - 1].context ?? sorted[i - 1].calendarName ?? ""
            let curr = sorted[i].context ?? sorted[i].calendarName ?? ""
            if prev != curr && !prev.isEmpty && !curr.isEmpty {
                switchCount += 1
            }
        }
        return switchCount >= 3
    }

    // MARK: - Timer

    private func startSuggestionTimer() {
        evaluate()
        suggestionTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluate()
            }
        }
    }

    deinit {
        suggestionTimer?.invalidate()
    }
}
