import Foundation
import BuboDomain

// MARK: - Optimizer Preferences

/// User preferences that influence optimization weights.
public struct OptimizerPreferences: Codable, Sendable {
    public var focusBlockWeight: Double
    public var pomodoroFitWeight: Double
    public var conflictWeight: Double
    public var taskPlacementWeight: Double
    public var weekBalanceWeight: Double
    public var energyCurveWeight: Double
    public var multiPersonWeight: Double
    public var breakWeight: Double
    public var deadlineWeight: Double
    public var contextSwitchWeight: Double
    public var bufferWeight: Double
    public var meetingClusteringWeight: Double
    public var taskInclusionWeight: Double
    /// Weight for `BacklogOrderObjective`. Optional so existing persisted
    /// preferences (JSON blobs without this key) still decode cleanly — a
    /// missing value reads through the default below. Consumers should route
    /// through that default instead of force-unwrapping.
    public var backlogOrderWeight: Double?

    /// Fallback when `backlogOrderWeight` is nil. Sized to match
    /// `taskPlacementWeight` (default 1.0) — backlog order is a
    /// first-class preference when the user asked to include the
    /// backlog, not a tiebreaker. At the previous 0.5 value a GA
    /// could save 5% of fitness via Buffer/ContextSwitch wins by
    /// violating three out of four desired-order pairs, which
    /// surfaced as "task 1 scheduled after tasks 2 and 3 on next
    /// week" patterns in the logs.
    public static let defaultBacklogOrderWeight: Double = 1.5

    /// Weight for `DayCompactnessObjective`. Optional so existing
    /// persisted preferences decode cleanly without the key.
    public var dayCompactnessWeight: Double?

    /// Fallback when `dayCompactnessWeight` is nil. Moderate — pulls
    /// same-day tasks together without overruling Buffer's "keep a
    /// few minutes between events" or BreakPlacement's hard break
    /// windows.
    public static let defaultDayCompactnessWeight: Double = 0.5

    // Energy model
    /// Hours of day the user considers peak productivity windows.
    /// A single-element set models the classic "one peak" case;
    /// multi-element sets let users with split energy (e.g. morning
    /// + post-lunch) nudge the planner toward multiple windows.
    /// Invariant: never empty — UI and intent boundary enforce this.
    public var peakEnergyHours: Set<Int>
    public var energyDecayRate: Double       // how fast energy drops
    /// Personal energy curve from check-in data (24 values, 0…1 per hour).
    /// nil = use static Gaussian centred on peakEnergyHours.
    public var personalEnergyCurve: [Double]?

    /// Representative single peak hour for callers that only accept one
    /// (e.g. `predictedCurve(defaultPeakHour:)`). Picks the earliest
    /// selected hour so it stays deterministic and matches the
    /// single-peak case exactly.
    public var primaryPeakEnergyHour: Int {
        peakEnergyHours.min() ?? 10
    }

    /// Smallest absolute distance, in hours, from `hour` to any peak
    /// hour. Used by fitness objectives so multi-peak users get
    /// credit for scheduling near any of their productive windows.
    public func peakEnergyDistance(from hour: Int) -> Int {
        peakEnergyHours.map { abs(hour - $0) }.min() ?? 0
    }

    /// Fractional-hour variant for callers that compute a Double hour
    /// (e.g. including minutes).
    public func peakEnergyDistance(from hour: Double) -> Double {
        peakEnergyHours.map { abs(hour - Double($0)) }.min() ?? 0
    }

    // Break rules
    public var maxConsecutiveMeetingMinutes: Int
    public var minBreakMinutes: Int
    public var lunchWindowStart: Int         // hour
    public var lunchWindowEnd: Int           // hour

    // Buffer rules
    public var defaultBufferMinutes: Int
    public var heavyMeetingBufferMinutes: Int

    // Balance
    public var maxMeetingsPerDay: Int
    public var idealFocusBlockMinutes: Int

    // Meeting clustering
    public var preferredClusterWindowStart: Int     // hour — meetings clustered after this
    public var preferredClusterWindowEnd: Int       // hour — meetings clustered before this
    public var maxMeetingsPerCluster: Int           // avoid marathon meeting blocks

    /// Weekdays on which the planner is allowed to place movable events.
    /// Uses Foundation's 1-indexed weekday convention
    /// (1 = Sunday, 2 = Monday, …, 7 = Saturday) so the values round-trip
    /// through `Calendar.component(.weekday, from:)` without translation.
    ///
    /// Default is Mon–Fri — matches the overwhelming common case and the
    /// original `skipWeekends = true` default this field replaced.
    /// Callers who want to allow Sat/Sun should set `Set(1...7)`.
    public var workingDays: Set<Int>

    /// Default weekdays for a brand-new install / seed context. Mon–Fri.
    public static let defaultWorkingDays: Set<Int> = [2, 3, 4, 5, 6]

    /// True iff `date`'s weekday is in `workingDays`. Every former
    /// weekend-aware check routes through this one helper so
    /// Mon/Wed/Fri-only or "work Saturdays" schedules behave
    /// correctly too — the planner simply follows the configured set.
    public func isWorkingDay(_ date: Date, calendar: Calendar) -> Bool {
        workingDays.contains(calendar.component(.weekday, from: date))
    }

    public init(
        focusBlockWeight: Double = 1.0,
        pomodoroFitWeight: Double = 0.8,
        conflictWeight: Double = 10.0,      // high penalty
        taskPlacementWeight: Double = 1.0,
        weekBalanceWeight: Double = 0.8,
        energyCurveWeight: Double = 0.9,
        multiPersonWeight: Double = 5.0,    // high priority
        breakWeight: Double = 1.2,
        deadlineWeight: Double = 3.0,       // important
        contextSwitchWeight: Double = 0.7,
        bufferWeight: Double = 0.6,
        meetingClusteringWeight: Double = 0.8,
        taskInclusionWeight: Double = 1.0,
        backlogOrderWeight: Double? = nil,
        dayCompactnessWeight: Double? = nil,
        peakEnergyHours: Set<Int> = [10],
        energyDecayRate: Double = 0.1,
        personalEnergyCurve: [Double]? = nil,
        maxConsecutiveMeetingMinutes: Int = 120,
        minBreakMinutes: Int = 10,
        lunchWindowStart: Int = 12,
        lunchWindowEnd: Int = 14,
        defaultBufferMinutes: Int = 5,
        heavyMeetingBufferMinutes: Int = 15,
        maxMeetingsPerDay: Int = 6,
        idealFocusBlockMinutes: Int = 120,
        preferredClusterWindowStart: Int = 9,
        preferredClusterWindowEnd: Int = 13,
        maxMeetingsPerCluster: Int = 4,
        workingDays: Set<Int> = OptimizerPreferences.defaultWorkingDays
    ) {
        self.focusBlockWeight = focusBlockWeight
        self.pomodoroFitWeight = pomodoroFitWeight
        self.conflictWeight = conflictWeight
        self.taskPlacementWeight = taskPlacementWeight
        self.weekBalanceWeight = weekBalanceWeight
        self.energyCurveWeight = energyCurveWeight
        self.multiPersonWeight = multiPersonWeight
        self.breakWeight = breakWeight
        self.deadlineWeight = deadlineWeight
        self.contextSwitchWeight = contextSwitchWeight
        self.bufferWeight = bufferWeight
        self.meetingClusteringWeight = meetingClusteringWeight
        self.taskInclusionWeight = taskInclusionWeight
        self.backlogOrderWeight = backlogOrderWeight
        self.dayCompactnessWeight = dayCompactnessWeight
        self.peakEnergyHours = peakEnergyHours
        self.energyDecayRate = energyDecayRate
        self.personalEnergyCurve = personalEnergyCurve
        self.maxConsecutiveMeetingMinutes = maxConsecutiveMeetingMinutes
        self.minBreakMinutes = minBreakMinutes
        self.lunchWindowStart = lunchWindowStart
        self.lunchWindowEnd = lunchWindowEnd
        self.defaultBufferMinutes = defaultBufferMinutes
        self.heavyMeetingBufferMinutes = heavyMeetingBufferMinutes
        self.maxMeetingsPerDay = maxMeetingsPerDay
        self.idealFocusBlockMinutes = idealFocusBlockMinutes
        self.preferredClusterWindowStart = preferredClusterWindowStart
        self.preferredClusterWindowEnd = preferredClusterWindowEnd
        self.maxMeetingsPerCluster = maxMeetingsPerCluster
        self.workingDays = workingDays
    }
}


