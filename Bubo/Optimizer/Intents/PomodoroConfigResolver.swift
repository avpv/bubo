import Foundation

// MARK: - Pomodoro Resolve Signals

/// Everything `PomodoroConfigResolver` needs to produce a `PomodoroConfig`.
/// All fields are optional: the resolver degrades gracefully when a signal is
/// missing (e.g. the user has no backlog task or no energy data yet).
///
/// Birman: "пусть потеет машина" — do not force the user to fill 4 numbers
/// when the app already knows the slot size, the task, the time of day and
/// the user's energy curve.
struct PomodoroResolveSignals: Equatable, Sendable {
    /// Largest continuous free window available for the session, in minutes.
    /// Hard ceiling on `totalMinutes` — the resolver will never return a
    /// config that won't fit.
    var availableMinutes: Int?

    /// Estimated work the backlog task actually needs, in minutes. Used to
    /// trim rounds: a 40-minute task doesn't need 4×25.
    var taskEstimateMinutes: Int?

    /// Story points of the task, 1…13. Higher = deeper cognitive load → prefer
    /// longer work intervals with fewer switches.
    var taskStoryPoints: Int?

    /// Days until the task's deadline (0 = today, negative = overdue).
    /// Tight deadlines bias toward more rounds and shorter breaks.
    var deadlineDaysAway: Int?

    /// Wall-clock hour the user will likely start the session. Defaults to
    /// the current hour if unknown.
    var currentHour: Int = 10

    /// User's peak-energy hour if known (e.g. from `.morningPerson` or an
    /// explicit `.peakEnergy(hour:)` intent).
    var peakEnergyHour: Int?

    /// Explicit low-energy signal (from `.lowEnergy` intent). Forces short
    /// work intervals and frequent breaks.
    var isLowEnergy: Bool = false

    /// Deep-work / focus priority boost (derived from the focus weight). When
    /// true, resolver leans toward longer work intervals.
    var wantsDeepWork: Bool = false

    /// User's historical preferred config, learned over time. Blended into
    /// the result — not yet populated, reserved for future use by
    /// `IntentLearner`.
    var learnedConfig: PomodoroConfig?
}

// MARK: - Pomodoro Config Resolver

/// Turns a set of signals into a concrete `PomodoroConfig` — continuous, not
/// snapped to a fixed catalogue of presets. Output is always inside safe
/// bounds and rounded to 5-minute increments for readability.
///
/// Design notes:
/// - Bounds are deliberately narrow so the result always looks like a
///   Pomodoro session and not an arbitrary timer: work ∈ [15, 60],
///   break ∈ [3, 15], rounds ∈ [1, 8].
/// - The resolver is pure: same signals → same config. Injectable signals
///   make unit testing trivial.
/// - When `availableMinutes` is tighter than the naive suggestion, the
///   resolver first drops the long break, then reduces rounds, then trims
///   work minutes — in that order, to preserve the ritual shape.
enum PomodoroConfigResolver {

    // MARK: Bounds

    static let minWorkMinutes = 15
    static let maxWorkMinutes = 60
    static let minBreakMinutes = 3
    static let maxBreakMinutes = 15
    static let minRounds = 1
    static let maxRounds = 8
    static let longBreakOptions = [0, 15, 20, 30]

    // MARK: Resolve

    static func resolve(signals: PomodoroResolveSignals) -> PomodoroConfig {
        var work = baseWorkMinutes(signals: signals)
        var breakDur = matchedBreak(for: work)

        // Tight deadlines prefer slightly shorter breaks — more time in work.
        if let days = signals.deadlineDaysAway, days <= 0 {
            breakDur = max(minBreakMinutes, breakDur - 2)
        }

        // Target total duration: bounded by slot size and task estimate.
        let target = targetTotalMinutes(signals: signals, work: work, breakDur: breakDur)

        // Compute rounds from target, then longBreak, then fit to budget.
        var rounds = roundsFor(targetMinutes: target, work: work, breakDur: breakDur)
        var longBreak = suggestedLongBreak(rounds: rounds, signals: signals)

        // Blend with learned config if present: nudge work toward the
        // learned value by ~30% (future — resolver is ready, data isn't).
        if let learned = signals.learnedConfig {
            work = snap5(Int(Double(work) * 0.7 + Double(learned.workMinutes) * 0.3))
            work = clamp(work, minWorkMinutes, maxWorkMinutes)
            breakDur = matchedBreak(for: work)
        }

        // Fit to the available window, dropping long break → rounds → work.
        var config = PomodoroConfig(
            workMinutes: work,
            breakMinutes: breakDur,
            rounds: rounds,
            longBreakMinutes: longBreak
        )
        if let budget = signals.availableMinutes, budget > 0 {
            if config.totalMinutes > budget {
                longBreak = 0
                config = PomodoroConfig(workMinutes: work, breakMinutes: breakDur, rounds: rounds, longBreakMinutes: longBreak)
            }
            while config.totalMinutes > budget && rounds > minRounds {
                rounds -= 1
                config = PomodoroConfig(workMinutes: work, breakMinutes: breakDur, rounds: rounds, longBreakMinutes: longBreak)
            }
            while config.totalMinutes > budget && work > minWorkMinutes {
                work = max(minWorkMinutes, work - 5)
                breakDur = matchedBreak(for: work)
                config = PomodoroConfig(workMinutes: work, breakMinutes: breakDur, rounds: rounds, longBreakMinutes: longBreak)
            }
        }

        return config
    }

    // MARK: - Internals

    /// Base work-interval length (minutes) driven by energy and deep-work
    /// signals. Snapped to 5.
    private static func baseWorkMinutes(signals: PomodoroResolveSignals) -> Int {
        if signals.isLowEnergy {
            return 15
        }
        var work = 25
        if let peak = signals.peakEnergyHour {
            let distance = abs(signals.currentHour - peak)
            switch distance {
            case 0...1: work = 45
            case 2...3: work = 30
            default:    work = 20
            }
        }
        if signals.wantsDeepWork {
            work = max(work, 45)
        }
        if let sp = signals.taskStoryPoints, sp >= 8 {
            work = max(work, 45)
        }
        return clamp(snap5(work), minWorkMinutes, maxWorkMinutes)
    }

    /// Break length proportional to work (classic 5:1) but clamped.
    private static func matchedBreak(for work: Int) -> Int {
        let proposed = snap5(max(minBreakMinutes, work / 5))
        return clamp(proposed, minBreakMinutes, maxBreakMinutes)
    }

    /// Target session wall-clock length, bounded by the task size and the
    /// available window. Without any hint we default to ~2 hours — the
    /// conventional "set of 4 pomodoros".
    private static func targetTotalMinutes(
        signals: PomodoroResolveSignals, work: Int, breakDur: Int
    ) -> Int {
        var target = 120
        if let est = signals.taskEstimateMinutes, est > 0 {
            // Give the task 10% slack; no more than one full cycle over the
            // estimate — otherwise we're stealing time from the next block.
            target = est + min(work + breakDur, est / 10 + work)
        }
        if let budget = signals.availableMinutes, budget > 0 {
            target = min(target, budget)
        }
        return max(work, target)
    }

    private static func roundsFor(targetMinutes: Int, work: Int, breakDur: Int) -> Int {
        // total = rounds * work + (rounds - 1) * break
        //       = rounds * (work + break) - break
        // rounds ≤ (target + break) / (work + break)
        let cycle = work + breakDur
        guard cycle > 0 else { return minRounds }
        let raw = (targetMinutes + breakDur) / cycle
        return clamp(raw, minRounds, maxRounds)
    }

    private static func suggestedLongBreak(rounds: Int, signals: PomodoroResolveSignals) -> Int {
        if rounds < 3 { return 0 }
        if signals.isLowEnergy { return 20 }
        if let days = signals.deadlineDaysAway, days <= 0 { return 15 }
        return rounds >= 5 ? 20 : 15
    }

    // MARK: Utilities

    private static func snap5(_ v: Int) -> Int {
        let r = Int((Double(v) / 5.0).rounded())
        return r * 5
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(v, lo), hi)
    }
}
