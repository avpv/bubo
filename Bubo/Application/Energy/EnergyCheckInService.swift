import Foundation
import BuboOptimizer

// MARK: - Energy Check-In Service

/// Collects user energy levels 2–3× daily and builds a personal energy curve.
/// The curve replaces the static "peak at 10:00" Gaussian in EnergyCurveObjective.
///
/// Over time, predictions improve by factoring in day-of-week and meeting load.
@MainActor
@Observable
final class EnergyCheckInService {

    // MARK: - Data Model

    /// A single energy reading from the user.
    struct CheckIn: Codable, Sendable {
        let timestamp: Date
        let energyLevel: Int          // 1–5
        let dayOfWeek: Int            // 1=Sun … 7=Sat
        let hour: Int                 // 0–23
        let meetingCount: Int         // meetings remaining today at check-in time
    }

    /// Precomputed hourly energy multiplier (0…1) for a given context.
    struct EnergyCurve: Codable, Sendable {
        /// Energy multiplier per hour (index 0–23). nil = not enough data yet.
        var hourlyEnergy: [Double?]

        /// Default static Gaussian curve centred on `peakHour`.
        static func defaultCurve(peakHour: Int) -> EnergyCurve {
            var values: [Double?] = Array(repeating: nil, count: 24)
            for h in 0..<24 {
                let dist = abs(Double(h) - Double(peakHour))
                values[h] = exp(-dist * dist * 0.02)
            }
            return EnergyCurve(hourlyEnergy: values)
        }

        /// Merge personal data with the static default — personal readings take
        /// precedence, gaps fall back to the Gaussian.
        func mergedWith(defaultPeakHour: Int) -> [Double] {
            let fallback = EnergyCurve.defaultCurve(peakHour: defaultPeakHour)
            return (0..<24).map { h in
                hourlyEnergy[h] ?? fallback.hourlyEnergy[h] ?? 0.5
            }
        }
    }

    // MARK: - State

    /// All recorded check-ins (persisted).
    private(set) var checkIns: [CheckIn] = []

    /// The current personal energy curve (recomputed after each check-in).
    private(set) var personalCurve: EnergyCurve?

    /// Non-nil when the service wants to prompt the user for a check-in.
    var pendingCheckIn: Bool = false

    /// Timestamp of the last prompt shown (persisted to survive app restart).
    private var lastPromptDate: Date? {
        didSet { persistLastPromptDate() }
    }

    /// Hours at which check-ins are prompted (spread across the workday).
    /// Persisted so that intent-configured hours survive across sessions.
    private(set) var promptHours: [Int] = [10, 14, 17] {
        didSet { persistPromptHours() }
    }

    private let checkInKey = "BuboEnergyCheckIns"
    private let lastPromptKey = "BuboEnergyLastPrompt"
    private let promptHoursKey = "BuboEnergyPromptHours"

    // MARK: - Init

    private var cloudSyncObserver: Any?

    init() {
        loadCheckIns()
        loadLastPromptDate()
        loadPromptHours()
        recomputeCurve()
        setupCloudSync()
    }

    private func setupCloudSync() {
        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: CloudSyncService.didReceiveRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let key = notification.object as? String,
                  key == "BuboEnergyCheckIns" else { return }
            Task { @MainActor [weak self] in
                self?.loadCheckIns()
                self?.recomputeCurve()
            }
        }
    }

    // MARK: - Configure

    /// Set prompt hours from intent configuration.
    /// Called once during setup, not per-optimization-run.
    func setPromptHours(_ hours: [Int]) {
        promptHours = hours.sorted()
    }

    // MARK: - Recording

    /// Record a user-reported energy level (1–5).
    /// Meeting count is derived from the reminder service automatically —
    /// the view should not count meetings itself.
    func record(energyLevel: Int, from reminderService: ReminderService) {
        let now = Date()
        let cal = Calendar.current
        let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let meetingCount = reminderService.allEvents.filter {
            !$0.isLocalEvent && $0.startDate >= now && $0.startDate < todayEnd
        }.count

        let checkIn = CheckIn(
            timestamp: now,
            energyLevel: min(5, max(1, energyLevel)),
            dayOfWeek: cal.component(.weekday, from: now),
            hour: cal.component(.hour, from: now),
            meetingCount: meetingCount
        )
        checkIns.append(checkIn)
        pendingCheckIn = false
        lastPromptDate = now
        saveCheckIns()
        recomputeCurve()
    }

    /// Dismiss the current check-in prompt without recording.
    func dismissCheckIn() {
        pendingCheckIn = false
        lastPromptDate = Date()
    }

    // MARK: - Prompt Logic

    /// Called periodically (by SuggestionEngine's 15-min timer).
    /// Sets `pendingCheckIn = true` when it's time for a reading.
    func evaluatePrompt() {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let weekday = cal.component(.weekday, from: now)

        // Only prompt on weekdays during prompt hours
        guard weekday >= 2 && weekday <= 6 else { return }
        guard promptHours.contains(hour) else { return }

        // Don't re-prompt within 90 minutes
        if let last = lastPromptDate,
           now.timeIntervalSince(last) < 90 * 60 {
            return
        }

        // Don't prompt if we already have a reading this hour today
        let todayStart = cal.startOfDay(for: now)
        let alreadyCheckedIn = checkIns.contains { ci in
            ci.timestamp >= todayStart && ci.hour == hour
        }
        guard !alreadyCheckedIn else { return }

        pendingCheckIn = true
    }

    // MARK: - Curve Computation

    /// Recompute the personal energy curve from all historical check-ins.
    /// Uses a weighted average: recent readings and same-day-of-week readings
    /// get higher weight.
    private func recomputeCurve() {
        guard !checkIns.isEmpty else {
            personalCurve = nil
            return
        }

        let now = Date()
        let currentWeekday = Calendar.current.component(.weekday, from: now)

        // Accumulate weighted sum per hour
        var weightedSum = Array(repeating: 0.0, count: 24)
        var totalWeight = Array(repeating: 0.0, count: 24)

        for ci in checkIns {
            let age = now.timeIntervalSince(ci.timestamp) / 86400  // days
            // Recency weight: exponential decay over 30 days
            let recencyWeight = exp(-age / 30.0)
            // Day-of-week bonus: same weekday gets 2× weight
            let dowWeight: Double = ci.dayOfWeek == currentWeekday ? 2.0 : 1.0
            let w = recencyWeight * dowWeight

            // Normalize energy level from 1–5 to 0–1
            let normalized = (Double(ci.energyLevel) - 1.0) / 4.0

            weightedSum[ci.hour] += normalized * w
            totalWeight[ci.hour] += w
        }

        var hourly: [Double?] = Array(repeating: nil, count: 24)
        for h in 0..<24 {
            if totalWeight[h] > 0.1 {  // need meaningful data
                hourly[h] = weightedSum[h] / totalWeight[h]
            }
        }

        personalCurve = EnergyCurve(hourlyEnergy: hourly)
    }

    // MARK: - Prediction

    /// Predict energy at a given hour, optionally for a specific day and meeting load.
    /// Returns 0…1 (normalized energy level).
    func predictEnergy(atHour hour: Int, dayOfWeek: Int? = nil, meetingCount: Int? = nil) -> Double? {
        guard !checkIns.isEmpty else { return nil }

        let targetDow = dayOfWeek ?? Calendar.current.component(.weekday, from: Date())
        let now = Date()

        // Filter to relevant check-ins for this hour (±1 hour window)
        let relevant = checkIns.filter { abs($0.hour - hour) <= 1 }
        guard !relevant.isEmpty else {
            return personalCurve?.hourlyEnergy[hour]
        }

        var weightedSum = 0.0
        var totalWeight = 0.0

        for ci in relevant {
            let age = now.timeIntervalSince(ci.timestamp) / 86400
            let recencyWeight = exp(-age / 30.0)
            let dowWeight: Double = ci.dayOfWeek == targetDow ? 2.0 : 1.0

            // Meeting load similarity: closer meeting counts get higher weight
            let meetingWeight: Double
            if let target = meetingCount {
                let diff = abs(ci.meetingCount - target)
                meetingWeight = 1.0 / (1.0 + Double(diff) * 0.5)
            } else {
                meetingWeight = 1.0
            }

            let w = recencyWeight * dowWeight * meetingWeight
            let normalized = (Double(ci.energyLevel) - 1.0) / 4.0

            weightedSum += normalized * w
            totalWeight += w
        }

        return totalWeight > 0.01 ? weightedSum / totalWeight : nil
    }

    /// Build a full 24-hour predicted curve for a specific day context.
    /// Returns array of 24 energy values (0…1), falling back to personal curve
    /// then static default for hours without enough data.
    func predictedCurve(dayOfWeek: Int, meetingCount: Int, defaultPeakHour: Int) -> [Double] {
        let fallback = personalCurve?.mergedWith(defaultPeakHour: defaultPeakHour)
            ?? EnergyCurve.defaultCurve(peakHour: defaultPeakHour).mergedWith(defaultPeakHour: defaultPeakHour)

        return (0..<24).map { h in
            predictEnergy(atHour: h, dayOfWeek: dayOfWeek, meetingCount: meetingCount) ?? fallback[h]
        }
    }

    // MARK: - Stats

    /// Number of unique days with at least one check-in.
    var daysWithData: Int {
        let cal = Calendar.current
        let uniqueDays = Set(checkIns.map { cal.startOfDay(for: $0.timestamp) })
        return uniqueDays.count
    }

    /// Whether we have enough data to produce a meaningful personal curve
    /// (at least 5 check-ins over 3+ days).
    var hasEnoughData: Bool {
        checkIns.count >= 5 && daysWithData >= 3
    }

    // MARK: - Persistence

    private func loadCheckIns() {
        guard let data = UserDefaults.standard.data(forKey: checkInKey),
              let decoded = try? JSONDecoder().decode([CheckIn].self, from: data) else { return }

        // Keep last 90 days of data
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        checkIns = decoded.filter { $0.timestamp >= cutoff }
    }

    private func saveCheckIns() {
        guard let data = try? JSONEncoder().encode(checkIns) else { return }
        UserDefaults.standard.set(data, forKey: checkInKey)
        CloudSyncService.shared.push(checkInKey)
    }

    private func loadLastPromptDate() {
        let ti = UserDefaults.standard.double(forKey: lastPromptKey)
        lastPromptDate = ti > 0 ? Date(timeIntervalSinceReferenceDate: ti) : nil
    }

    private func persistLastPromptDate() {
        if let date = lastPromptDate {
            UserDefaults.standard.set(date.timeIntervalSinceReferenceDate, forKey: lastPromptKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastPromptKey)
        }
    }

    private func loadPromptHours() {
        let arr = UserDefaults.standard.array(forKey: promptHoursKey) as? [Int]
        if let arr, !arr.isEmpty {
            promptHours = arr.sorted()
        }
    }

    private func persistPromptHours() {
        UserDefaults.standard.set(promptHours, forKey: promptHoursKey)
    }
}
