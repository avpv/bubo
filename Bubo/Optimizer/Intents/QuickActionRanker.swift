import Foundation

// MARK: - Quick Action Ranker

/// Ranks quick actions using a scoring algorithm inspired by Hacker News.
///
/// Score = (points × contextBoost) / (T + 2)^gravity
///
/// Where:
/// - points = usage count × acceptance rate
/// - contextBoost = how well this action matches current schedule state (0...3)
/// - T = hours since this action was last relevant
/// - gravity = 1.8 (how fast old actions decay)
///
/// Context signals boost actions that are relevant RIGHT NOW:
/// - Overdue tasks → boost "Schedule tasks"
/// - No focus today → boost "Focus"
/// - 5+ meetings → boost "Batch meetings"
/// - Morning → boost "Organize"
///
/// Usage history makes frequently-accepted actions rise,
/// frequently-rejected actions sink.
@MainActor
struct QuickActionRanker {

    let backlogService: BacklogService
    let reminderService: ReminderService
    let intentLearner: IntentLearner

    private let gravity: Double = 1.8

    // MARK: - Rank

    /// Returns the top N quick actions ranked by score.
    func rank(limit: Int = 3) -> [ScoredAction] {
        let candidates = generateCandidates()
        let scored = candidates.map { candidate in
            ScoredAction(
                action: candidate,
                score: score(candidate)
            )
        }
        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    struct ScoredAction: Identifiable {
        var id: String { action.id }
        let action: QuickActionCandidate
        let score: Double
    }

    // MARK: - Scoring

    private func score(_ candidate: QuickActionCandidate) -> Double {
        let points = usagePoints(candidate)
        let contextBoost = contextScore(candidate)
        let timePenalty = timeDecay(candidate)

        // HN formula: score = (points * boost) / (T + 2)^gravity
        // Modified: contextBoost is multiplicative (not additive like HN points)
        // so contextually irrelevant actions get near-zero even if historically popular
        return (points * contextBoost) / timePenalty
    }

    /// Usage points: how much the user likes this action.
    /// Based on acceptance rate and frequency from IntentLearner.
    private func usagePoints(_ candidate: QuickActionCandidate) -> Double {
        let key = candidate.id
        let frequency = Double(intentLearner.intentFrequency[key] ?? 0)
        let history = intentLearner.history

        // Count accepts and rejects for requests containing this action's key intents
        var accepts = 0
        var rejects = 0
        for execution in history {
            let matchesCandidate = candidate.request.intents.contains { intent in
                execution.intents.contains(intent)
            }
            if matchesCandidate {
                switch execution.outcome {
                case .accepted: accepts += 1
                case .rejected: rejects += 1
                case .modified: accepts += 1  // modified = partially accepted
                }
            }
        }

        let total = accepts + rejects
        let acceptanceRate = total > 0 ? Double(accepts) / Double(total) : 0.5  // default 50%

        // Points = base (1) + frequency bonus + acceptance bonus
        // New actions start at 1.0, popular accepted ones go higher
        return 1.0 + (frequency * 0.3) + (acceptanceRate * 2.0)
    }

    /// Context score: how relevant is this action RIGHT NOW.
    /// 0 = completely irrelevant, 1 = baseline, 3 = urgently needed.
    private func contextScore(_ candidate: QuickActionCandidate) -> Double {
        switch candidate.signal {
        case .overdueExists:
            let overdue = backlogService.overdue
            return overdue.isEmpty ? 0 : min(3.0, 1.0 + Double(overdue.count) * 0.5)

        case .urgentDeadline:
            let urgent = backlogService.urgent(withinDays: 2)
            return urgent.isEmpty ? 0 : min(3.0, 1.5 + Double(urgent.count) * 0.3)

        case .pendingTasks:
            let pending = backlogService.pending
            return pending.isEmpty ? 0 : min(2.5, 0.5 + Double(pending.count) * 0.2)

        case .noFocusToday:
            let cal = Calendar.current
            let now = Date()
            let hour = cal.component(.hour, from: now)
            let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            let hasFocus = reminderService.allEvents.contains {
                $0.startDate >= now && $0.startDate < todayEnd && $0.eventType == .pomodoro
            }
            if hasFocus { return 0 }
            // More relevant in morning, less in evening
            return hour < 10 ? 2.5 : hour < 14 ? 1.8 : hour < 17 ? 0.8 : 0

        case .meetingHeavy:
            let cal = Calendar.current
            let now = Date()
            let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            let meetings = reminderService.allEvents.filter {
                $0.startDate >= now && $0.startDate < todayEnd && !$0.isLocalEvent
            }
            return meetings.count >= 5 ? min(2.5, 1.0 + Double(meetings.count - 4) * 0.3) : 0

        case .morningOrganize:
            let hour = Calendar.current.component(.hour, from: Date())
            return hour < 10 ? 2.0 : hour < 11 ? 1.0 : 0

        case .planTomorrow:
            let hour = Calendar.current.component(.hour, from: Date())
            return hour >= 16 ? 1.5 : hour >= 14 ? 0.5 : 0

        case .lowEnergy:
            let hour = Calendar.current.component(.hour, from: Date())
            // Post-lunch dip
            return (13...15).contains(hour) ? 1.5 : 0

        case .alwaysAvailable:
            return 0.3  // low baseline, only shows if nothing better
        }
    }

    /// Time decay: actions lose relevance over time since last context match.
    /// Uses HN gravity formula: (T + 2)^gravity
    private func timeDecay(_ candidate: QuickActionCandidate) -> Double {
        // Find last time this action was relevant (executed or context-matched)
        let lastRelevant = lastRelevantTime(candidate)
        let hoursSince = Date().timeIntervalSince(lastRelevant) / 3600.0
        return pow(hoursSince + 2.0, gravity)
    }

    private func lastRelevantTime(_ candidate: QuickActionCandidate) -> Date {
        // Check IntentLearner history for last execution of matching intents
        let matching = intentLearner.history.filter { execution in
            candidate.request.intents.contains { intent in
                execution.intents.contains(intent)
            }
        }
        if let last = matching.last {
            return last.timestamp
        }
        // Never used → treat as "just now" so it gets a chance
        return Date()
    }

    // MARK: - Candidates

    /// All possible quick actions. Each has a context signal that determines relevance.
    private func generateCandidates() -> [QuickActionCandidate] {
        let pending = backlogService.pending

        var candidates: [QuickActionCandidate] = [
            QuickActionCandidate(
                id: "deadlines",
                label: "Deadlines",
                icon: "exclamationmark.circle.fill",
                request: .deadlineMode,
                signal: .urgentDeadline
            ),
            QuickActionCandidate(
                id: "schedule-tasks",
                label: "Schedule \(pending.count)",
                icon: "calendar.badge.plus",
                request: .scheduleBacklog,
                signal: .pendingTasks
            ),
            QuickActionCandidate(
                id: "focus",
                label: "Focus",
                icon: "scope",
                request: .findFocus(),
                signal: .noFocusToday
            ),
            QuickActionCandidate(
                id: "organize",
                label: "Organize",
                icon: "wand.and.stars",
                request: .organizeDay,
                signal: .morningOrganize
            ),
            QuickActionCandidate(
                id: "batch-meetings",
                label: "Batch meetings",
                icon: "person.3.fill",
                request: .batchMeetingsPreset,
                signal: .meetingHeavy
            ),
            QuickActionCandidate(
                id: "plan-tomorrow",
                label: "Plan tomorrow",
                icon: "sun.horizon.fill",
                request: OptimizationRequest(
                    .horizon(.tomorrow), .includeBacklog,
                    .speed(.balanced), .scenarios(count: 2),
                    name: "Plan tomorrow"
                ),
                signal: .planTomorrow
            ),
            QuickActionCandidate(
                id: "low-energy",
                label: "Low energy",
                icon: "battery.25percent",
                request: .lowEnergyDay,
                signal: .lowEnergy
            ),
        ]

        // Add overdue-specific action if overdue tasks exist
        let overdue = backlogService.overdue
        if !overdue.isEmpty {
            candidates.insert(QuickActionCandidate(
                id: "overdue",
                label: "Overdue \(overdue.count)",
                icon: "clock.badge.exclamationmark.fill",
                request: OptimizationRequest(
                    .includeBacklog, .findSlotsForBacklog,
                    .prioritizeDeadlines(weight: 3.0),
                    .horizon(.today), .speed(.quick), .scenarios(count: 1),
                    name: "Fix overdue"
                ),
                signal: .overdueExists
            ), at: 0)
        }

        return candidates
    }
}

// MARK: - Quick Action Candidate

struct QuickActionCandidate: Identifiable {
    let id: String
    let label: String
    let icon: String
    let request: OptimizationRequest
    let signal: ContextSignal
}

/// What schedule state makes this action relevant.
enum ContextSignal: Sendable {
    case overdueExists
    case urgentDeadline
    case pendingTasks
    case noFocusToday
    case meetingHeavy
    case morningOrganize
    case planTomorrow
    case lowEnergy
    case alwaysAvailable
}
