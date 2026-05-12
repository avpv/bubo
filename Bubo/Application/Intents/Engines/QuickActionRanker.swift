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

    nonisolated static let gravity: Double = 1.8

    // MARK: - Rank

    /// Returns the top N quick actions ranked by score.
    func rank(limit: Int = 3) -> [ScoredAction] {
        let inputs = gatherContextInputs()
        let candidates = generateCandidates()
        let now = Date()
        let scored = candidates.map { candidate in
            ScoredAction(
                action: candidate,
                score: score(candidate, inputs: inputs, now: now),
                reason: Self.reason(for: candidate.signal, inputs: inputs)
            )
        }
        return scored
            .sorted { lhs, rhs in
                // Tie-break on id ensures deterministic order across re-ranks,
                // preventing button-order flicker when scores are equal.
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.action.id < rhs.action.id
            }
            .prefix(limit)
            .map { $0 }
    }

    struct ScoredAction: Identifiable {
        var id: String { action.id }
        let action: QuickActionCandidate
        let score: Double
        /// Human-readable reason this action surfaced in the chip row.
        /// Surfaced via `.help(...)` on each chip so the user can audit
        /// «why is this here?» — Birman: make the machinery visible,
        /// not magical. Empty string for `.alwaysAvailable` chips
        /// (the answer would be tautological).
        let reason: String
    }

    /// Maps a context signal + inputs to a short human-readable reason.
    /// Used as the tooltip on each surfaced chip so users can audit
    /// the ranker's decisions.
    nonisolated static func reason(
        for signal: ContextSignal,
        inputs: ContextInputs
    ) -> String {
        switch signal {
        case .overdueExists:
            let n = inputs.overdueCount
            return "\(n) overdue task\(n == 1 ? "" : "s")"
        case .urgentDeadline:
            let n = inputs.urgentCount
            return "\(n) deadline\(n == 1 ? "" : "s") within 2 days"
        case .pendingTasks:
            let n = inputs.pendingCount
            return "\(n)\u{00A0}task\(n == 1 ? "" : "s") to schedule"
        case .noFocusToday:
            return "No focus block today"
        case .meetingHeavy:
            return "\(inputs.meetingsTodayCount) meetings today"
        case .morningOrganize:
            return "Morning planning window"
        case .planTomorrow:
            return "Plan tomorrow before signing off"
        case .lowEnergy:
            return "Post-lunch energy dip"
        case .alwaysAvailable:
            return ""
        }
    }

    // MARK: - Context inputs

    /// Snapshot of all values needed for context scoring. Gathered once per
    /// `rank()` call so the expensive `reminderService.allEvents` (recurrence
    /// expansion) is only walked once even though multiple signals depend on it.
    struct ContextInputs: Sendable {
        let overdueCount: Int
        let urgentCount: Int
        let pendingCount: Int
        let hour: Int
        let hasFocusToday: Bool
        let meetingsTodayCount: Int
    }

    private func gatherContextInputs() -> ContextInputs {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!

        // Walk allEvents once and bucket what each signal needs.
        var hasFocus = false
        var meetings = 0
        for event in reminderService.allEvents
        where event.startDate >= now && event.startDate < todayEnd {
            if event.eventType == .pomodoro { hasFocus = true }
            if !event.isLocalEvent { meetings += 1 }
        }

        return ContextInputs(
            overdueCount: backlogService.overdue.count,
            urgentCount: backlogService.urgent(withinDays: 2).count,
            pendingCount: backlogService.schedulable.count,
            hour: hour,
            hasFocusToday: hasFocus,
            meetingsTodayCount: meetings
        )
    }

    // MARK: - Scoring

    private func score(
        _ candidate: QuickActionCandidate,
        inputs: ContextInputs,
        now: Date
    ) -> Double {
        let points = usagePoints(candidate)
        let contextBoost = Self.contextScore(for: candidate.signal, inputs: inputs)
        let hoursSince = now.timeIntervalSince(lastRelevantTime(candidate)) / 3600.0
        return Self.combinedScore(
            points: points,
            contextBoost: contextBoost,
            hoursSinceRelevant: hoursSince
        )
    }

    /// HN-inspired: (points * boost) / (T + 2)^gravity.
    /// contextBoost is multiplicative so contextually irrelevant actions
    /// get near-zero even if historically popular.
    nonisolated static func combinedScore(
        points: Double,
        contextBoost: Double,
        hoursSinceRelevant: Double,
        gravity: Double = QuickActionRanker.gravity
    ) -> Double {
        let timePenalty = pow(hoursSinceRelevant + 2.0, gravity)
        return (points * contextBoost) / timePenalty
    }

    private func usagePoints(_ candidate: QuickActionCandidate) -> Double {
        let key = candidate.id
        let frequency = intentLearner.intentFrequency[key] ?? 0
        let history = intentLearner.history

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
                case .modified: accepts += 1  // partial accept
                }
            }
        }

        return Self.usagePoints(frequency: frequency, accepts: accepts, rejects: rejects)
    }

    /// New actions start at 2.0 (1 base + 50% default acceptance × 2);
    /// each frequency unit adds 0.3, full acceptance adds 2.0.
    nonisolated static func usagePoints(frequency: Int, accepts: Int, rejects: Int) -> Double {
        let total = accepts + rejects
        let acceptanceRate = total > 0 ? Double(accepts) / Double(total) : 0.5
        return 1.0 + (Double(frequency) * 0.3) + (acceptanceRate * 2.0)
    }

    /// Maps a context signal to a relevance multiplier (0…3).
    /// 0 = irrelevant, 1 = baseline, 3 = urgent.
    nonisolated static func contextScore(
        for signal: ContextSignal,
        inputs: ContextInputs
    ) -> Double {
        switch signal {
        case .overdueExists:
            return inputs.overdueCount == 0
                ? 0
                : min(3.0, 1.0 + Double(inputs.overdueCount) * 0.5)

        case .urgentDeadline:
            return inputs.urgentCount == 0
                ? 0
                : min(3.0, 1.5 + Double(inputs.urgentCount) * 0.3)

        case .pendingTasks:
            return inputs.pendingCount == 0
                ? 0
                : min(2.5, 0.5 + Double(inputs.pendingCount) * 0.2)

        case .noFocusToday:
            if inputs.hasFocusToday { return 0 }
            return inputs.hour < 10 ? 2.5
                : inputs.hour < 14 ? 1.8
                : inputs.hour < 17 ? 0.8
                : 0

        case .meetingHeavy:
            return inputs.meetingsTodayCount >= 5
                ? min(2.5, 1.0 + Double(inputs.meetingsTodayCount - 4) * 0.3)
                : 0

        case .morningOrganize:
            return inputs.hour < 10 ? 2.0 : inputs.hour < 11 ? 1.0 : 0

        case .planTomorrow:
            return inputs.hour >= 16 ? 1.5 : inputs.hour >= 14 ? 0.5 : 0

        case .lowEnergy:
            // Post-lunch dip.
            return (13...15).contains(inputs.hour) ? 1.5 : 0

        case .alwaysAvailable:
            return 0.3
        }
    }

    private func lastRelevantTime(_ candidate: QuickActionCandidate) -> Date {
        let matching = intentLearner.history.filter { execution in
            candidate.request.intents.contains { intent in
                execution.intents.contains(intent)
            }
        }
        if let last = matching.last {
            return last.timestamp
        }
        // Never used → treat as "just now" so it gets a chance.
        return Date()
    }

    // MARK: - Candidates

    /// Pick the focus-tile variant the user is most likely to want.
    ///
    /// We compare per-intent usage frequency for the two focus modes
    /// ("focus" = ad-hoc focus block, "pomodoro" = structured session)
    /// and surface the one with the higher count. Ties — and brand-new
    /// users with no history — default to plain Focus, the more general
    /// of the two. Once the user has run a few Pomodoro sessions, the
    /// tile flips automatically.
    ///
    /// Birman: let the machine remember what the user likes, rather than
    /// forcing them to pick between two nearly identical options every time.
    private func focusVariantCandidate() -> QuickActionCandidate {
        let focusFreq = intentLearner.intentFrequency["focus"] ?? 0
        let pomodoroFreq = intentLearner.intentFrequency["pomodoro"] ?? 0
        if pomodoroFreq > focusFreq {
            return QuickActionCandidate(
                id: "pomodoro",
                label: "Pomodoro",
                icon: "timer",
                request: .pomodoroBlock,
                signal: .noFocusToday
            )
        }
        return QuickActionCandidate(
            id: "focus",
            label: "Focus",
            icon: "scope",
            request: .findFocus(),
            signal: .noFocusToday
        )
    }

    /// All possible quick actions. Each has a context signal that determines relevance.
    private func generateCandidates() -> [QuickActionCandidate] {
        let schedulable = backlogService.schedulable

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
                label: "Schedule \(schedulable.count)",
                icon: "calendar.badge.plus",
                request: .scheduleBacklog,
                signal: .pendingTasks
            ),
            // ONE focus tile — Pomodoro or plain Focus — chosen by the
            // user's history. Birman: don't show two options for the same
            // user need; pick the one the user actually uses. New users
            // (no history) see "Focus" as the safer default; once they
            // start running Pomodoro sessions, the tile flips to Pomodoro.
            focusVariantCandidate(),
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
