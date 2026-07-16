import Foundation
import BuboDomain

// MARK: - Proactive-Reactive Policy (Wave 5 / item 17)
//
// Two-stage optimization layered over the existing GA: a baseline
// schedule is produced proactively (as today), plus a reactive policy
// for a short list of high-likelihood disturbances. When reality
// deviates ("the 2pm meeting ran long", "someone added an urgent
// item"), the policy produces an instant corrective schedule without
// re-running the full GA.
//
// The value proposition is "fragility insurance": a baseline that
// degrades gracefully under common shocks, not one that optimises
// for a static world. Stochastic RCPSP literature (Herroelen & Leus,
// 2005+) formalises this as proactive (robust) + reactive (policy)
// scheduling.
//
// The reactive half here is a finite state machine. Disturbance
// types we handle:
//   • `meetingDelayed`: the current meeting ran over by N minutes.
//   • `meetingCancelled`: the slot is now free.
//   • `urgentTaskInserted`: a new high-priority task just appeared.
//   • `participantUnavailable`: someone can't make a scheduled slot.
// For each, the policy emits a `Recovery` containing the gene-level
// edits to apply. The caller executes the edits and runs
// `BuboOptimizer.instantReflow` for polish.

/// A disturbance the scheduler should react to.
public enum ScheduleDisturbance: Sendable {
    case meetingDelayed(eventId: String, overrunMinutes: Int)
    case meetingCancelled(eventId: String)
    case urgentTaskInserted(event: OptimizableEvent)
    case participantUnavailable(participantId: String, window: DateInterval)
}

/// Recovery action: a batch of gene edits + any new genes to insert.
public struct ScheduleRecovery: Sendable {

    public init(
        shifts: [String: Date],
        removals: Set<String>,
        insertions: [ScheduleGene],
        reflowAfter: Bool
    ) {
        self.shifts = shifts
        self.removals = removals
        self.insertions = insertions
        self.reflowAfter = reflowAfter
    }

    /// Existing genes to reschedule (eventId → new startTime).
    public let shifts: [String: Date]
    /// Existing genes to drop entirely (e.g. the cancelled one).
    public let removals: Set<String>
    /// Brand-new genes to insert (e.g. the urgent task).
    public let insertions: [ScheduleGene]
    /// Whether the caller should run a full `instantReflow` after
    /// applying. Policies that make local edits don't need this;
    /// ones that cascade do.
    public let reflowAfter: Bool

    public static let noop = ScheduleRecovery(
        shifts: [:], removals: [], insertions: [], reflowAfter: false
    )
}

public final class ProactiveReactivePolicy: @unchecked Sendable {
    public struct Configuration: Sendable {

        public init(
            cascadeOverrunThreshold: Int,
            urgentPriorityCutoff: Double,
            rescheduleHorizonDays: Int
        ) {
            self.cascadeOverrunThreshold = cascadeOverrunThreshold
            self.urgentPriorityCutoff = urgentPriorityCutoff
            self.rescheduleHorizonDays = rescheduleHorizonDays
        }

        /// How much overrun triggers a cascading shift (as opposed
        /// to absorbing into the next buffer). Minutes.
        public let cascadeOverrunThreshold: Int
        /// Priority cutoff above which a task counts as "urgent".
        public let urgentPriorityCutoff: Double
        /// How far ahead (in working days) we look for a free slot
        /// when rescheduling around a disturbance.
        public let rescheduleHorizonDays: Int

        public static let `default` = Configuration(
            cascadeOverrunThreshold: 15,
            urgentPriorityCutoff: 0.8,
            rescheduleHorizonDays: 3
        )
    }

    public let config: Configuration
    public init(config: Configuration = .default) {
        self.config = config
    }

    // MARK: - React

    /// Produce a recovery for the given disturbance, based on the
    /// current schedule's state. Pure function of the schedule and
    /// the disturbance — idempotent, retryable.
    public func react(
        disturbance: ScheduleDisturbance,
        currentSchedule: [ScheduleGene],
        context: OptimizerContext
    ) -> ScheduleRecovery {
        switch disturbance {
        case .meetingDelayed(let id, let overrunMinutes):
            return reactToDelay(
                eventId: id,
                overrunMinutes: overrunMinutes,
                schedule: currentSchedule,
                context: context
            )
        case .meetingCancelled(let id):
            return reactToCancellation(eventId: id)
        case .urgentTaskInserted(let event):
            return reactToUrgent(event: event, schedule: currentSchedule, context: context)
        case .participantUnavailable(let pid, let window):
            return reactToUnavailability(
                participantId: pid,
                window: window,
                schedule: currentSchedule,
                context: context
            )
        }
    }

    // MARK: - Delay

    private func reactToDelay(
        eventId: String,
        overrunMinutes: Int,
        schedule: [ScheduleGene],
        context: OptimizerContext
    ) -> ScheduleRecovery {
        guard let offender = schedule.first(where: { $0.eventId == eventId }) else {
            return .noop
        }
        let offendingEnd = offender.endTime.addingTimeInterval(TimeInterval(overrunMinutes * 60))
        var shifts: [String: Date] = [:]
        // Everything starting before offendingEnd on the same day
        // cascades forward.
        let cal = context.calendar
        let day = cal.startOfDay(for: offender.startTime)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: day) ?? offendingEnd

        // Only cascade when overrun is significant.
        if overrunMinutes < config.cascadeOverrunThreshold {
            return .noop
        }
        // Determine the sequence of conflicted events. The lower bound
        // matters: only genes that are still running when the delayed
        // meeting started (or start after it) can be impacted — without
        // `endTime > offender.startTime`, a 9:00 standup that finished
        // hours before a delayed 14:00 meeting (or a gene on a previous
        // day) would be "recovered" to the late afternoon.
        let impactedGenes = schedule
            .filter { $0.eventId != eventId }
            .filter {
                $0.startTime < dayEnd
                    && $0.startTime < offendingEnd
                    && $0.endTime > offender.startTime
            }
            .sorted { $0.startTime < $1.startTime }
        var cursor = offendingEnd
        for gene in impactedGenes {
            if gene.startTime >= cursor {
                cursor = gene.endTime
                continue
            }
            shifts[gene.eventId] = cursor
            cursor = cursor.addingTimeInterval(gene.duration)
        }
        return ScheduleRecovery(
            shifts: shifts,
            removals: [],
            insertions: [],
            reflowAfter: !shifts.isEmpty
        )
    }

    // MARK: - Cancellation

    private func reactToCancellation(eventId: String) -> ScheduleRecovery {
        ScheduleRecovery(
            shifts: [:],
            removals: [eventId],
            insertions: [],
            reflowAfter: true
        )
    }

    // MARK: - Urgent insertion

    private func reactToUrgent(
        event: OptimizableEvent,
        schedule: [ScheduleGene],
        context: OptimizerContext
    ) -> ScheduleRecovery {
        // Idempotence: the event is already on the schedule — a
        // retried `.urgentTaskInserted` must not find a "free" slot
        // next to the first copy and insert a second one.
        guard !schedule.contains(where: { $0.eventId == event.id }) else {
            return .noop
        }
        // Find the earliest free slot within the reschedule horizon.
        let cal = context.calendar
        let workStart = context.workingHours.lowerBound
        let workEnd = context.workingHours.upperBound
        var cursor = max(Date(), context.planningHorizon.start)
        let horizonEnd = min(
            context.planningHorizon.end,
            cal.date(byAdding: .day, value: config.rescheduleHorizonDays, to: cursor) ?? context.planningHorizon.end
        )
        let sorted = schedule.sorted { $0.startTime < $1.startTime }

        while cursor < horizonEnd {
            // Snap cursor to next working-hour slot if outside.
            let hour = cal.component(.hour, from: cursor)
            if hour < workStart {
                cursor = cal.date(bySettingHour: workStart, minute: 0, second: 0, of: cursor) ?? cursor
            } else if hour >= workEnd {
                if let nextDay = cal.date(byAdding: .day, value: 1, to: cursor) {
                    let nd = cal.startOfDay(for: nextDay)
                    cursor = cal.date(bySettingHour: workStart, minute: 0, second: 0, of: nd) ?? nd
                } else {
                    break
                }
                continue
            }
            let end = cursor.addingTimeInterval(event.duration)
            // Date comparison against the day's actual working end —
            // the old hour-component check (`endHour > workEnd`)
            // accepted ends up to workEnd:59, and an end past midnight
            // has hour 0–2, which passes for any workEnd.
            let dayWorkEnd = cal.date(
                bySettingHour: workEnd, minute: 0, second: 0,
                of: cal.startOfDay(for: cursor)
            )
            if let dayWorkEnd, end > dayWorkEnd {
                if let nextDay = cal.date(byAdding: .day, value: 1, to: cursor) {
                    let nd = cal.startOfDay(for: nextDay)
                    cursor = cal.date(bySettingHour: workStart, minute: 0, second: 0, of: nd) ?? nd
                    continue
                }
                break
            }
            let conflicts = sorted.first { gene in
                gene.startTime < end && cursor < gene.endTime
            }
            if conflicts == nil {
                let gene = ScheduleGene(
                    eventId: event.id,
                    title: event.title,
                    startTime: cursor,
                    duration: event.duration,
                    context: event.context,
                    energyCost: event.energyCost,
                    priority: event.priority,
                    isFocusBlock: event.isFocusBlock,
                    storyPoints: event.storyPoints,
                    isDroppable: event.isDroppable,
                    isIncluded: true,
                    pomodoroConfig: event.pomodoroConfig,
                    reservedTaskIds: event.reservedTaskIds,
                    slotIndex: context.ensureSlotRegistry().nearestIndex(to: cursor)
                )
                return ScheduleRecovery(
                    shifts: [:],
                    removals: [],
                    insertions: [gene],
                    reflowAfter: event.priority >= config.urgentPriorityCutoff
                )
            }
            cursor = conflicts!.endTime
        }
        // No free slot in horizon: reflow after insertion at horizon start
        // and let the optimizer resolve by evicting a low-priority gene.
        let horizonStart = context.planningHorizon.start
        let gene = ScheduleGene(
            eventId: event.id,
            title: event.title,
            startTime: horizonStart,
            duration: event.duration,
            context: event.context,
            energyCost: event.energyCost,
            priority: event.priority,
            isFocusBlock: event.isFocusBlock,
            storyPoints: event.storyPoints,
            isDroppable: event.isDroppable,
            isIncluded: true,
            pomodoroConfig: event.pomodoroConfig,
            reservedTaskIds: event.reservedTaskIds,
            slotIndex: context.ensureSlotRegistry().nearestIndex(to: horizonStart)
        )
        return ScheduleRecovery(
            shifts: [:], removals: [], insertions: [gene], reflowAfter: true
        )
    }

    // MARK: - Unavailability

    private func reactToUnavailability(
        participantId: String,
        window: DateInterval,
        schedule: [ScheduleGene],
        context: OptimizerContext
    ) -> ScheduleRecovery {
        // Find any gene whose participant list contains `participantId`
        // and whose slot overlaps `window`. Shift each to the next
        // feasible slot after the window.
        //
        // Since `ScheduleGene` doesn't carry participant metadata,
        // we consult `context.movableEvents` to resolve participants.
        let events = Dictionary(uniqueKeysWithValues: context.movableEvents.map { ($0.id, $0) })
        var shifts: [String: Date] = [:]
        let cal = context.calendar
        for gene in schedule {
            guard let event = events[gene.eventId] else { continue }
            guard event.requiredParticipants.contains(participantId) else { continue }
            if gene.endTime <= window.start || gene.startTime >= window.end { continue }
            // Move to next working-hour slot after window.end.
            var cursor = window.end
            let hour = cal.component(.hour, from: cursor)
            if hour < context.workingHours.lowerBound {
                cursor = cal.date(
                    bySettingHour: context.workingHours.lowerBound,
                    minute: 0, second: 0, of: cursor
                ) ?? cursor
            } else if hour >= context.workingHours.upperBound {
                if let nextDay = cal.date(byAdding: .day, value: 1, to: cursor) {
                    let nd = cal.startOfDay(for: nextDay)
                    cursor = cal.date(
                        bySettingHour: context.workingHours.lowerBound,
                        minute: 0, second: 0, of: nd
                    ) ?? nd
                }
            }
            shifts[gene.eventId] = cursor
        }
        return ScheduleRecovery(
            shifts: shifts,
            removals: [],
            insertions: [],
            reflowAfter: !shifts.isEmpty
        )
    }
}

// MARK: - Recovery application

public extension ScheduleRecovery {
    /// Apply the recovery to a gene array, producing the adjusted
    /// schedule. Optional `registry` binds `slotIndex` on shifted
    /// genes so the return set arrives at the GA already slot-aware;
    /// when nil (tests, legacy paths) shifted genes get a nil
    /// `slotIndex` and the GA's repair pass re-binds them on first
    /// touch — still correct, just pays one extra eval.
    func applied(to schedule: [ScheduleGene], registry: SlotRegistry? = nil) -> [ScheduleGene] {
        var result = schedule.compactMap { gene -> ScheduleGene? in
            if removals.contains(gene.eventId) { return nil }
            if let newStart = shifts[gene.eventId] {
                if let registry {
                    return gene.withSlot(nearest: newStart, registry: registry)
                }
                return ScheduleGene(
                    eventId: gene.eventId,
                    title: gene.title,
                    startTime: newStart,
                    duration: gene.duration,
                    context: gene.context,
                    energyCost: gene.energyCost,
                    priority: gene.priority,
                    isFocusBlock: gene.isFocusBlock,
                    storyPoints: gene.storyPoints,
                    isDroppable: gene.isDroppable,
                    isIncluded: gene.isIncluded,
                    pomodoroConfig: gene.pomodoroConfig,
                    reservedTaskIds: gene.reservedTaskIds,
                    groupId: gene.groupId,
                    slotIndex: nil
                )
            }
            return gene
        }
        // Idempotence: a retried disturbance (UI double-fire, retry
        // after a perceived failure) must not stack a second gene for
        // the same event — replace an existing gene with the same
        // eventId instead of appending a duplicate.
        for insertion in insertions {
            if let existing = result.firstIndex(where: { $0.eventId == insertion.eventId }) {
                result[existing] = insertion
            } else {
                result.append(insertion)
            }
        }
        return result
    }
}
