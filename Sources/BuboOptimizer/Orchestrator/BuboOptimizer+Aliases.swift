import Foundation
import BuboDomain

// MARK: - BuboOptimizer aliases & shortcuts
//
// Convenience wrappers over the main optimize(...) pipeline.
// Extracted from BuboOptimizer.swift.

public extension BuboOptimizer {

    // MARK: - Pareto Optimize (alias)

    /// NSGA-III is now the default survivor-selection strategy, so this
    /// method is a thin alias over `optimize`. Kept to avoid breaking
    /// callers that specifically asked for Pareto-aware scenarios.
    public func optimizeWithPareto(
        context: OptimizerContext,
        overrideConfig: GAConfiguration? = nil,
        overrideIslandConfig: IslandConfiguration? = nil
    ) async -> OptimizerResult {
        await optimize(
            context: context,
            overrideConfig: overrideConfig,
            overrideIslandConfig: overrideIslandConfig
        )
    }

    // MARK: - Quick Optimize (Day)

    public func optimizeToday(
        fixedEvents: [CalendarEvent],
        movableEvents: [OptimizableEvent],
        workingHours: ClosedRange<Int> = 9...18
    ) async -> OptimizerResult {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart)!

        let context = OptimizerContext(
            fixedEvents: fixedEvents.filter { $0.startDate >= todayStart && $0.startDate < todayEnd },
            movableEvents: movableEvents,
            workingHours: workingHours,
            planningHorizon: DateInterval(start: max(Date(), todayStart), end: todayEnd),
            preferences: preferences
        )

        return await optimize(context: context, overrideConfig: .quick, overrideIslandConfig: .quick)
    }

    // MARK: - Weekly Optimize

    public func optimizeWeek(
        fixedEvents: [CalendarEvent],
        movableEvents: [OptimizableEvent],
        workingHours: ClosedRange<Int> = 9...18,
        participantAvailability: [String: [DateInterval]] = [:]
    ) async -> OptimizerResult {
        let now = Date()
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: now)!

        // `workingDays` is a non-optional `Set<Int>` on preferences
        // (default Mon–Fri); pass `preferences` through as-is. Direct
        // callers that don't override `workingDays` in their own
        // `OptimizerPreferences()` get the Mon–Fri default baked into
        // the initializer.
        let context = OptimizerContext(
            fixedEvents: fixedEvents,
            movableEvents: movableEvents,
            workingHours: workingHours,
            planningHorizon: DateInterval(start: now, end: weekEnd),
            preferences: preferences,
            participantAvailability: participantAvailability
        )

        // No `overrideConfig` here — let `optimize()` choose via its
        // own CP-SAT → dispatch pipeline:
        //   difficulty < 0.25  → `.polish`
        //   difficulty < 0.6   → `.refine`
        //   otherwise          → the instance's `gaConfig`
        // The old `configForWorkload` inline-interpolation was
        // duplicating this logic with slightly different constants
        // and bypassing the polish / refine presets by arriving as
        // an override. Removed for a single source of truth.
        return await optimize(context: context)
    }


    /// Combined workload difficulty scalar in [0.05, 1.0].
    ///
    /// `countFactor` is asymptotic — 30 tasks pushes the factor to
    /// ~0.95, 50 tasks to ~0.99. `densityFactor` looks at week
    /// saturation: 40 movable hours over a 5-day × 9-hour working
    /// week saturates the schedule and forces more search even if N
    /// is small. Taking the *max* of the two means either factor
    /// alone can trigger the heavy tier — a handful of very long
    /// tasks doesn't get under-served.
    public func workloadDifficulty(
        movableEvents: [OptimizableEvent],
        fixedEvents: [CalendarEvent]
    ) -> Double {
        let n = Double(movableEvents.count)
        // Saturating curve: N=1 → ~0.04, N=8 → ~0.30, N=20 → ~0.60,
        // N=40 → ~0.90. Half-life around 20 tasks.
        let countFactor = 1.0 - exp(-n / 20.0)

        // Planning horizon is 7 days in optimizeWeek; we approximate
        // the weekday working hours by 5 × 9h = 45h. Fixed events eat
        // into that budget — subtract their total duration from the
        // denominator so a calendar already half-full with meetings
        // pushes the density up.
        let movableHours = movableEvents.reduce(0.0) { $0 + $1.duration / 3600.0 }
        let fixedHours = fixedEvents.reduce(0.0) { acc, ev in
            acc + ev.endDate.timeIntervalSince(ev.startDate) / 3600.0
        }
        let availableHours = max(5.0, 45.0 - fixedHours)
        let densityFactor = min(1.0, movableHours / availableHours)

        return max(Self.workloadDifficultyFloor, min(1.0, max(countFactor, densityFactor)))
    }

}
