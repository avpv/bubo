import Foundation

// MARK: - Pomodoro Resolver Tuning

/// Every magic number the resolver reaches for, in one place. Makes the
/// policy inspectable, unit-testable, and overridable — the numbers aren't
/// gone, they're just named and justified.
///
/// Birman: «arbitrary numbers should simply be rounded» — all minute-valued
/// fields are multiples of 5 and stay inside `workBounds` / `breakBounds`.
struct PomodoroResolverTuning: Equatable, Sendable {

    // Hard bounds on the session shape.
    var workBounds: ClosedRange<Int>       = 15...60
    var breakBounds: ClosedRange<Int>      = 3...15
    var roundBounds: ClosedRange<Int>      = 1...8
    var longBreakOptions: [Int]            = [0, 15, 20, 30]

    // Base work-minute choice by energy context.
    var lowEnergyWork: Int                 = 15
    var defaultWork: Int                   = 25
    var nearPeakWork: Int                  = 45
    var farFromPeakWork: Int               = 20

    /// Hours-from-peak → work bucket edges. `[1, 3]` means distance ≤ 1 is
    /// "near", ≤ 3 is "regular", else "far".
    var peakDistanceBuckets: [Int]         = [1, 3]

    /// Story-points threshold at which work is pushed toward deep-work mode.
    var deepTaskStoryPoints: Int           = 8

    /// Break minutes shaved off when the deadline is today/overdue.
    var tightDeadlineBreakPenalty: Int     = 2

    /// Default target session length when no task estimate is given.
    var defaultTargetMinutes: Int          = 120

    /// Slack added to a task estimate when choosing the target. Never more
    /// than one cycle to avoid stealing time from the next block.
    var taskEstimateSlackPercent: Int      = 10

    /// How strongly learned history blends into the computed work value.
    /// 0 = ignore history, 1 = trust history fully. 0.3 keeps history as a
    /// nudge rather than a dictate.
    var historyBlend: Double               = 0.3

    /// Round count at/above which a long break is added.
    var longBreakRoundThreshold: Int       = 3

    static let `default` = PomodoroResolverTuning()
}

// MARK: - Pomodoro Resolve Signals

/// Everything `PomodoroConfigResolver` needs to produce a `PomodoroConfig`.
/// All fields are optional: the resolver degrades gracefully when a signal is
/// missing (e.g. the user has no backlog task or no history yet).
struct PomodoroResolveSignals: Equatable, Sendable {
    /// Largest continuous free window available for the session, in minutes.
    /// Hard ceiling on `totalMinutes` — the resolver will never return a
    /// config that won't fit.
    var availableMinutes: Int?

    /// Estimated work the backlog task actually needs, in minutes. Used to
    /// trim rounds: a 40-minute task doesn't need 4 × 25.
    var taskEstimateMinutes: Int?

    /// Story points of the task, 1…13. Higher = deeper cognitive load → prefer
    /// longer work intervals with fewer switches.
    var taskStoryPoints: Int?

    /// Days until the task's deadline (0 = today, negative = overdue).
    /// Tight deadlines bias toward more rounds and shorter breaks.
    var deadlineDaysAway: Int?

    /// Hour the session is expected to start. Defaults to the current hour
    /// during pre-GA compilation; `resolveShape` re-reads this with the
    /// actual placed-slot hour post-GA.
    var startHour: Int = 10

    /// User's peak-energy hour if known (e.g. from `.morningPerson` or an
    /// explicit `.peakEnergy(hour:)` intent).
    var peakEnergyHour: Int?

    /// Explicit low-energy signal (from `.lowEnergy` intent). Forces short
    /// work intervals and frequent breaks.
    var isLowEnergy: Bool = false

    /// Deep-work / focus priority boost (derived from the focus weight). When
    /// true, resolver leans toward longer work intervals.
    var wantsDeepWork: Bool = false

    /// User's historical preferred config at roughly the same time of day.
    /// Blended into the result via `tuning.historyBlend`.
    var learnedConfig: PomodoroConfig?
}

// MARK: - Pomodoro Config Resolver

/// Turns a set of signals into a concrete `PomodoroConfig` — continuous, not
/// snapped to a fixed catalogue of presets. Split into two phases so the
/// compiler can fix the total duration pre-GA and refine the inner shape
/// post-placement using the slot's real start hour.
///
/// `resolveDuration(signals)` — pre-GA. Decides how many minutes to carve
/// out of the day. Drives slot-finding.
///
/// `resolveShape(totalMinutes:startHour:signals:)` — post-GA. Fills
/// work/break/rounds/longBreak inside a fixed budget using the actual hour
/// the optimizer picked.
///
/// `resolve(signals)` — one-shot for callers (tests, fallback paths) that
/// don't have a post-GA hook.
enum PomodoroConfigResolver {

    // MARK: One-shot

    static func resolve(
        signals: PomodoroResolveSignals,
        tuning: PomodoroResolverTuning = .default
    ) -> PomodoroConfig {
        let duration = resolveDuration(signals: signals, tuning: tuning)
        return resolveShape(
            totalMinutes: duration,
            startHour: signals.startHour,
            signals: signals,
            tuning: tuning
        )
    }

    // MARK: Duration (pre-GA)

    /// Target total session length in minutes. Bounded by the free slot,
    /// the task estimate, and the resolver's default target.
    static func resolveDuration(
        signals: PomodoroResolveSignals,
        tuning: PomodoroResolverTuning = .default
    ) -> Int {
        var target = tuning.defaultTargetMinutes
        if let est = signals.taskEstimateMinutes, est > 0 {
            let slack = max(5, est * tuning.taskEstimateSlackPercent / 100)
            target = est + slack
        }
        if let budget = signals.availableMinutes, budget > 0 {
            target = min(target, budget)
        }
        // Ensure at least one full minimum work interval fits.
        return max(tuning.workBounds.lowerBound, snap5(target))
    }

    // MARK: Shape (post-GA)

    /// Fill work / break / rounds / long break so the session fits exactly
    /// inside `totalMinutes`, using `startHour` to decide work intensity.
    static func resolveShape(
        totalMinutes: Int,
        startHour: Int,
        signals: PomodoroResolveSignals,
        tuning: PomodoroResolverTuning = .default
    ) -> PomodoroConfig {
        var signalsAtHour = signals
        signalsAtHour.startHour = startHour

        var work = baseWorkMinutes(signals: signalsAtHour, tuning: tuning)
        var breakDur = matchedBreak(for: work, tuning: tuning)

        if let days = signals.deadlineDaysAway, days <= 0 {
            breakDur = clamp(breakDur - tuning.tightDeadlineBreakPenalty, tuning.breakBounds)
        }

        if let learned = signals.learnedConfig {
            let blend = tuning.historyBlend
            work = snap5(Int(Double(work) * (1 - blend) + Double(learned.workMinutes) * blend))
            work = clamp(work, tuning.workBounds)
            breakDur = matchedBreak(for: work, tuning: tuning)
        }

        var rounds = roundsFor(
            targetMinutes: max(totalMinutes, work),
            work: work,
            breakDur: breakDur,
            tuning: tuning
        )
        var longBreak = suggestedLongBreak(rounds: rounds, signals: signals, tuning: tuning)

        var config = PomodoroConfig(
            workMinutes: work, breakMinutes: breakDur,
            rounds: rounds, longBreakMinutes: longBreak
        )
        // Fit to budget: drop long break → reduce rounds → trim work.
        if totalMinutes > 0 && config.totalMinutes > totalMinutes {
            longBreak = 0
            config = PomodoroConfig(workMinutes: work, breakMinutes: breakDur, rounds: rounds, longBreakMinutes: 0)
        }
        while totalMinutes > 0 && config.totalMinutes > totalMinutes && rounds > tuning.roundBounds.lowerBound {
            rounds -= 1
            config = PomodoroConfig(workMinutes: work, breakMinutes: breakDur, rounds: rounds, longBreakMinutes: longBreak)
        }
        while totalMinutes > 0 && config.totalMinutes > totalMinutes && work > tuning.workBounds.lowerBound {
            work = max(tuning.workBounds.lowerBound, work - 5)
            breakDur = matchedBreak(for: work, tuning: tuning)
            config = PomodoroConfig(workMinutes: work, breakMinutes: breakDur, rounds: rounds, longBreakMinutes: longBreak)
        }
        return config
    }

    // MARK: - Internals

    private static func baseWorkMinutes(
        signals: PomodoroResolveSignals, tuning: PomodoroResolverTuning
    ) -> Int {
        if signals.isLowEnergy {
            return tuning.lowEnergyWork
        }
        var work = tuning.defaultWork
        if let peak = signals.peakEnergyHour {
            let distance = abs(signals.startHour - peak)
            let buckets = tuning.peakDistanceBuckets
            let nearEdge = buckets.first ?? 1
            let regularEdge = buckets.dropFirst().first ?? 3
            switch distance {
            case 0...nearEdge:       work = tuning.nearPeakWork
            case (nearEdge + 1)...regularEdge: work = tuning.defaultWork
            default:                 work = tuning.farFromPeakWork
            }
        }
        if signals.wantsDeepWork {
            work = max(work, tuning.nearPeakWork)
        }
        if let sp = signals.taskStoryPoints, sp >= tuning.deepTaskStoryPoints {
            work = max(work, tuning.nearPeakWork)
        }
        return clamp(snap5(work), tuning.workBounds)
    }

    private static func matchedBreak(for work: Int, tuning: PomodoroResolverTuning) -> Int {
        let proposed = snap5(max(tuning.breakBounds.lowerBound, work / 5))
        return clamp(proposed, tuning.breakBounds)
    }

    private static func roundsFor(
        targetMinutes: Int, work: Int, breakDur: Int, tuning: PomodoroResolverTuning
    ) -> Int {
        // total(rounds) = rounds * (work + break) - break
        // rounds ≤ (target + break) / (work + break)
        let cycle = work + breakDur
        guard cycle > 0 else { return tuning.roundBounds.lowerBound }
        let raw = (targetMinutes + breakDur) / cycle
        return clamp(raw, tuning.roundBounds)
    }

    private static func suggestedLongBreak(
        rounds: Int, signals: PomodoroResolveSignals, tuning: PomodoroResolverTuning
    ) -> Int {
        guard rounds >= tuning.longBreakRoundThreshold else { return 0 }
        if signals.isLowEnergy { return 20 }
        if let days = signals.deadlineDaysAway, days <= 0 { return 15 }
        return rounds >= 5 ? 20 : 15
    }

    // MARK: - Utilities

    private static func snap5(_ v: Int) -> Int {
        let r = Int((Double(v) / 5.0).rounded())
        return r * 5
    }

    private static func clamp(_ v: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(v, range.lowerBound), range.upperBound)
    }
}
