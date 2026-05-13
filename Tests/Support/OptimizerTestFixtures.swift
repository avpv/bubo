import Foundation
import Testing
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - Shared test helpers
//
// Minimal fixture helpers shared across the per-module tests in this
// directory. Kept here so each module-test file only contains what's
// unique to that module.

enum OptimizerTestFixtures {
    static func makeContext(
        movableEvents: [OptimizableEvent] = [],
        fixedEvents: [CalendarEvent] = [],
        workingHours: ClosedRange<Int> = 9...18,
        seed: UInt64 = 4242
    ) -> OptimizerContext {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        return OptimizerContext(
            fixedEvents: fixedEvents,
            movableEvents: movableEvents,
            workingHours: workingHours,
            planningHorizon: DateInterval(start: today, end: tomorrow),
            preferences: OptimizerPreferences(),
            rng: GARandom(seed: seed)
        )
    }

    static func makeEvent(
        id: String,
        durationMinutes: Int = 60,
        priority: Double = 0.5,
        isFocusBlock: Bool = false
    ) -> OptimizableEvent {
        OptimizableEvent(
            id: id,
            title: id,
            duration: TimeInterval(durationMinutes * 60),
            priority: priority,
            isFocusBlock: isFocusBlock
        )
    }
}
