import Foundation
@testable import Bubo
@testable import BuboDomain
@testable import BuboOptimizer

// MARK: - Test-only gene helpers

/// Legacy-style helper retained only for tests. Production code was
/// migrated to `ScheduleGene.withSlot(nearest:registry:)` /
/// `ScheduleGene.withSlot(index:date:)` in the slot-decoder step 2
/// pass, but most tests don't build a `SlotRegistry` and just want to
/// move a gene to a new `Date` for constraint/fitness assertions.
///
/// Keeping this on a test-only extension means the shortcut is
/// visible here but can't leak back into production modules —
/// `@testable import Bubo` doesn't propagate extensions defined in
/// the test target.
extension ScheduleGene {
    /// Test-only: return a copy with the supplied `startTime` and a
    /// cleared `slotIndex`. Same semantics as the removed production
    /// `withStartTime(_:)`. New tests should reach for
    /// `withSlot(nearest:registry:)` once they have a registry; use
    /// this only when the test genuinely doesn't care about slot
    /// binding.
    func withStartTime(_ newStart: Date) -> ScheduleGene {
        ScheduleGene(
            eventId: eventId,
            title: title,
            startTime: newStart,
            duration: duration,
            context: context,
            energyCost: energyCost,
            priority: priority,
            isFocusBlock: isFocusBlock,
            storyPoints: storyPoints,
            isDroppable: isDroppable,
            isIncluded: isIncluded,
            pomodoroConfig: pomodoroConfig,
            reservedTaskIds: reservedTaskIds,
            groupId: groupId,
            slotIndex: nil
        )
    }
}
