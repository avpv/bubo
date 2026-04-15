import Foundation

// MARK: - Intent Learner

/// Learns user's intent preferences from accept/reject patterns.
/// Tracks which intent combinations are used and accepted,
/// then suggests popular combos automatically.
///
/// Unlike PreferenceLearner (which learns fitness weights),
/// this learns the *structure* of requests — what intents users combine.
@MainActor
@Observable
final class IntentLearner {

    /// History of executed requests with outcomes.
    private(set) var history: [IntentExecution] = []

    /// Learned intent co-occurrence scores.
    private(set) var coOccurrence: [String: [String: Double]] = [:]

    /// Frequently used individual intents ranked by usage.
    private(set) var intentFrequency: [String: Int] = [:]

    /// Temporal patterns: intents associated with time-of-day/day-of-week.
    private(set) var temporalPatterns: [TemporalPattern] = []

    private let persistenceKey = "BuboIntentLearnerHistory"
    private var cloudSyncObserver: Any?

    init() {
        load()
        setupCloudSync()
    }

    private func setupCloudSync() {
        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: CloudSyncService.didReceiveRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let key = notification.object as? String,
                  key.hasPrefix("BuboIntentLearnerHistory") else { return }
            Task { @MainActor [weak self] in
                self?.load()
            }
        }
    }

    // MARK: - Record

    struct IntentExecution: Codable {
        let intents: [ScheduleIntent]
        let name: String?
        let outcome: Outcome
        let timestamp: Date
        let hour: Int
        let dayOfWeek: Int

        enum Outcome: String, Codable {
            case accepted
            case rejected
            case modified
        }
    }

    func recordExecution(_ request: OptimizationRequest, outcome: IntentExecution.Outcome) {
        let cal = Calendar.current
        let now = Date()
        let execution = IntentExecution(
            intents: request.intents,
            name: request.name,
            outcome: outcome,
            timestamp: now,
            hour: cal.component(.hour, from: now),
            dayOfWeek: cal.component(.weekday, from: now)
        )
        history.append(execution)

        // Update frequency and co-occurrence
        if outcome == .accepted {
            updateFrequency(request.intents)
            updateCoOccurrence(request.intents)
            updateTemporalPatterns(request.intents, hour: execution.hour, dayOfWeek: execution.dayOfWeek)
        }

        // Prune old history (keep last 200)
        if history.count > 200 {
            history = Array(history.suffix(200))
        }

        save()
    }

    // MARK: - Suggestions

    /// Suggest intents that pair well with the given intents,
    /// based on learned co-occurrence patterns.
    func suggestedCompanions(for intents: [ScheduleIntent], limit: Int = 5) -> [ScheduleIntent] {
        guard !intents.isEmpty else { return topIntents(limit: limit) }

        var scores: [String: Double] = [:]
        for intent in intents {
            let key = intentKey(intent)
            if let companions = coOccurrence[key] {
                for (companionKey, score) in companions {
                    scores[companionKey, default: 0] += score
                }
            }
        }

        // Remove intents already present
        let presentKeys = Set(intents.map { intentKey($0) })
        scores = scores.filter { !presentKeys.contains($0.key) }

        // Sort by score, return top N as suggested intents
        let topKeys = scores.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
        return topKeys.compactMap { knownIntents[$0] }
    }

    /// Suggest a complete request based on time-of-day patterns.
    func suggestedRequestForNow() -> OptimizationRequest? {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let dayOfWeek = cal.component(.weekday, from: now)

        // Find patterns matching current time
        let matching = temporalPatterns.filter { pattern in
            pattern.hourRange.contains(hour) &&
            (pattern.daysOfWeek.isEmpty || pattern.daysOfWeek.contains(dayOfWeek))
        }

        guard let best = matching.max(by: { $0.confidence < $1.confidence }) else { return nil }
        guard best.confidence >= 0.3 else { return nil }  // minimum confidence threshold

        return OptimizationRequest(
            best.intents,
            name: best.name,
            description: "Suggested based on your patterns"
        )
    }

    /// Top N most frequently used intents.
    func topIntents(limit: Int = 5) -> [ScheduleIntent] {
        intentFrequency
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { knownIntents[$0.key] }
    }

    // MARK: - Internal Updates

    private func updateFrequency(_ intents: [ScheduleIntent]) {
        for intent in intents {
            let key = intentKey(intent)
            intentFrequency[key, default: 0] += 1
        }
    }

    private func updateCoOccurrence(_ intents: [ScheduleIntent]) {
        guard intents.count >= 2 else { return }
        for i in 0..<intents.count {
            for j in (i + 1)..<intents.count {
                let keyI = intentKey(intents[i])
                let keyJ = intentKey(intents[j])
                coOccurrence[keyI, default: [:]][keyJ, default: 0] += 1
                coOccurrence[keyJ, default: [:]][keyI, default: 0] += 1
            }
        }
    }

    private func updateTemporalPatterns(_ intents: [ScheduleIntent], hour: Int, dayOfWeek: Int) {
        // Find existing pattern or create new one
        let hourRange = hourBucket(hour)
        if let idx = temporalPatterns.firstIndex(where: {
            $0.hourRange == hourRange && Set($0.intents) == Set(intents)
        }) {
            temporalPatterns[idx].occurrences += 1
            if !temporalPatterns[idx].daysOfWeek.contains(dayOfWeek) {
                temporalPatterns[idx].daysOfWeek.append(dayOfWeek)
            }
        } else {
            temporalPatterns.append(TemporalPattern(
                intents: intents,
                name: "Pattern at \(hourRange.lowerBound):00",
                hourRange: hourRange,
                daysOfWeek: [dayOfWeek],
                occurrences: 1
            ))
        }

        // Recalculate confidence for all patterns
        let totalExecutions = max(1, history.filter { $0.outcome == .accepted }.count)
        for i in temporalPatterns.indices {
            temporalPatterns[i].confidence = Double(temporalPatterns[i].occurrences) / Double(totalExecutions)
        }

        // Prune low-confidence patterns
        temporalPatterns.removeAll { $0.occurrences < 2 && $0.confidence < 0.05 }
    }

    /// Bucket hours into ranges: morning (6-12), afternoon (12-17), evening (17-22), night (22-6)
    private func hourBucket(_ hour: Int) -> ClosedRange<Int> {
        switch hour {
        case 6..<12: return 6...11
        case 12..<17: return 12...16
        case 17..<22: return 17...21
        default: return 22...5
        }
    }

    // MARK: - Intent Key Mapping

    /// Stable string key for an intent (for dictionary storage).
    private func intentKey(_ intent: ScheduleIntent) -> String {
        switch intent {
        case .noEventsBefore: return "noEventsBefore"
        case .noEventsAfter: return "noEventsAfter"
        case .workingHours: return "workingHours"
        case .horizon(let h): return "horizon.\(h.rawValue)"
        case .focusBlock: return "focusBlock"
        case .createBlock: return "createBlock"
        case .pomodoroSession: return "pomodoroSession"
        case .prioritizeDeadlines: return "prioritizeDeadlines"
        case .prioritizeFocus: return "prioritizeFocus"
        case .minimizeContextSwitching: return "minimizeContextSwitching"
        case .groupByProject: return "groupByProject"
        case .batchMeetings: return "batchMeetings"
        case .lowEnergy: return "lowEnergy"
        case .peakEnergy: return "peakEnergy"
        case .morningPerson: return "morningPerson"
        case .protectLunch: return "protectLunch"
        case .breakEvery: return "breakEvery"
        case .maxMeetings: return "maxMeetings"
        case .stability(let s): return "stability.\(s.rawValue)"
        case .keepFixed: return "keepFixed"
        case .exclude: return "exclude"
        case .onlyOptimize: return "onlyOptimize"
        case .preferPeriod: return "preferPeriod"
        case .includeBacklog: return "includeBacklog"
        case .includeBacklogTasks: return "includeBacklogTasks"
        case .limitToTopTasks: return "limitToTopTasks"
        case .findSlotsForBacklog: return "findSlotsForBacklog"
        case .speed(let s): return "speed.\(s.rawValue)"
        case .scenarios: return "scenarios"
        case .contingencyBuffer: return "contingencyBuffer"
        case .focusProtection: return "focusProtection"
        case .meetingPrep: return "meetingPrep"
        case .windDown: return "windDown"
        case .taskOrder: return "taskOrder"
        case .minGap: return "minGap"
        case .flexDuration: return "flexDuration"
        case .likeYesterday: return "likeYesterday"
        case .halfDay: return "halfDay"
        case .warmUp: return "warmUp"
        case .coolDown: return "coolDown"
        case .travelBuffer: return "travelBuffer"
        case .endOfDayReview: return "endOfDayReview"
        case .matchEnergyCurve: return "matchEnergyCurve"
        case .timeBox: return "timeBox"
        case .syncWith: return "syncWith"
        case .officeHours: return "officeHours"
        case .pairWork: return "pairWork"
        case .noOverlap: return "noOverlap"
        case .microBreak: return "microBreak"
        case .walkBreak: return "walkBreak"
        case .pinAt: return "pinAt"
        case .noScreensAfter: return "noScreensAfter"
        case .batchByTool: return "batchByTool"
        case .deepShallowSplit: return "deepShallowSplit"
        case .groupByLocation: return "groupByLocation"
        case .uninterruptedBlock: return "uninterruptedBlock"
        case .stretchGoals: return "stretchGoals"
        case .overflowToTomorrow: return "overflowToTomorrow"
        case .energyCheckIn: return "energyCheckIn"
        case .todayOnly: return "todayOnly"
        case .until: return "until"
        case .skipWeekends: return "skipWeekends"
        case .fromCalendar: return "fromCalendar"
        case .fromProject: return "fromProject"
        case .fromTimeRange: return "fromTimeRange"
        case .splitLong: return "splitLong"
        case .addBuffer: return "addBuffer"
        case .capTotal: return "capTotal"
        case .mergeAdjacent: return "mergeAdjacent"
        case .when: return "when"
        case .autoApply: return "autoApply"
        case .notify: return "notify"
        case .chainThen: return "chainThen"
        case .saveAsPreset: return "saveAsPreset"
        case .onEventDeleted: return "onEventDeleted"
        case .onNewEvent: return "onNewEvent"
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .onCalendarSync: return "onCalendarSync"
        }
    }

    /// Reverse mapping: key → canonical intent instance.
    private var knownIntents: [String: ScheduleIntent] {
        [
            "noEventsBefore": .noEventsBefore(hour: 11),
            "noEventsAfter": .noEventsAfter(hour: 17),
            "horizon.today": .horizon(.today),
            "horizon.tomorrow": .horizon(.tomorrow),
            "horizon.week": .horizon(.week),
            "focusBlock": .focusBlock(minutes: 120),
            "pomodoroSession": .pomodoroSession(),
            "prioritizeDeadlines": .prioritizeDeadlines(),
            "prioritizeFocus": .prioritizeFocus(),
            "minimizeContextSwitching": .minimizeContextSwitching(),
            "groupByProject": .groupByProject(),
            "batchMeetings": .batchMeetings(),
            "lowEnergy": .lowEnergy,
            "morningPerson": .morningPerson,
            "protectLunch": .protectLunch(),
            "breakEvery": .breakEvery(workMinutes: 60, breakMinutes: 10),
            "maxMeetings": .maxMeetings(perDay: 3),
            "includeBacklog": .includeBacklog,
            "findSlotsForBacklog": .findSlotsForBacklog,
            "speed.quick": .speed(.quick),
            "speed.balanced": .speed(.balanced),
            "speed.thorough": .speed(.thorough),
            "stability.normal": .stability(.normal),
            "stability.conservative": .stability(.conservative),
        ]
    }

    // MARK: - Temporal Pattern

    struct TemporalPattern: Codable {
        var intents: [ScheduleIntent]
        var name: String
        var hourRange: ClosedRange<Int>
        var daysOfWeek: [Int]  // 1=Sun, 2=Mon, ...
        var occurrences: Int
        var confidence: Double = 0
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
            CloudSyncService.shared.push(persistenceKey)
        }
        if let data = try? JSONEncoder().encode(temporalPatterns) {
            UserDefaults.standard.set(data, forKey: persistenceKey + ".patterns")
            CloudSyncService.shared.push(persistenceKey + ".patterns")
        }
        if let data = try? JSONEncoder().encode(intentFrequency) {
            UserDefaults.standard.set(data, forKey: persistenceKey + ".frequency")
            CloudSyncService.shared.push(persistenceKey + ".frequency")
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode([IntentExecution].self, from: data) {
            history = decoded
        }
        if let data = UserDefaults.standard.data(forKey: persistenceKey + ".patterns"),
           let decoded = try? JSONDecoder().decode([TemporalPattern].self, from: data) {
            temporalPatterns = decoded
        }
        if let data = UserDefaults.standard.data(forKey: persistenceKey + ".frequency"),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            intentFrequency = decoded
        }

        // Rebuild co-occurrence from history
        for execution in history where execution.outcome == .accepted {
            updateCoOccurrence(execution.intents)
        }
    }
}
