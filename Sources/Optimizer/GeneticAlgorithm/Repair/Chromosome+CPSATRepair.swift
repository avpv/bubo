import Foundation

// MARK: - ScheduleChromosome CP-SAT LNS-repair bridge
//
// `applyCPSATRepair(...)` converts the LNS "destroyed" gene window
// into CP-SAT inputs, drives the in-process branch-and-bound solver
// (`CPSATRepairer`), and writes the resulting assignments back. When
// the solver times out without a complete assignment, the caller in
// `Chromosome+Mutation.swift` falls back to `regretRepair`.
//
// Sibling files in the same LNS pipeline:
//   • `Chromosome+LNSDestroy.swift` — `destroy(strategy:...)` picks
//     which gene indices to rip out before repair.
//   • `Chromosome+CPRepair.swift` — `cpRepair(...)`, the handwritten
//     CP-SAT-lite alternative used when no external adapter is wired.
//   • `Chromosome+RegretRepair.swift` — `regretRepair(...)` fallback
//     when the budget runs out without a complete assignment.
//
// Access notes (from prior extractions in `Chromosome.swift`):
//   • `OccupiedInterval` was `fileprivate`, now internal.
//   • `findFirstFreeSlot`, `findLastFreeSlot`, `enumerateFeasibleSlots`
//     are internal so these files can call them.
//   • `applyCPSATRepair`, `destroy`, `cpRepair`, `regretRepair` are
//     internal so `applyLNS` in `Chromosome+Mutation.swift` can drive
//     this pipeline across files.

public extension ScheduleChromosome {

    // MARK: - CP-SAT Repair Bridge

    /// Convert the destroyed gene window into CP-SAT inputs, run the
    /// adapter, and write the assignments back. Returns the IndexSet
    /// of mutated indices, or nil when the adapter timed out without
    /// producing a complete assignment — caller falls back to the
    /// handwritten branch-and-bound.
    ///
    /// Domain construction: per gene, generate slot candidates at
    /// 30-minute resolution within (planningHorizon ∩ working hours).
    /// Sorted by absolute distance from the gene's current
    /// startTime so the solver's preferred-order heuristic respects
    /// locality. Score function rewards small total displacement
    /// and any included-event placement.
    // Internal (was `private`) so `applyLNS(...)` in
    // `Chromosome+Mutation.swift` can drive the CP-SAT repair pass
    // after destroying a window of genes.
    mutating func applyCPSATRepair(
        destroyed: [Int],
        using repairer: CPSATRepairer,
        context: OptimizerContext
    ) -> IndexSet? {
        let cal = context.calendar
        let horizon = context.planningHorizon
        let workStart = context.workingHours.lowerBound
        let workEnd = context.workingHours.upperBound
        let slotRegistry = context.ensureSlotRegistry()

        // Build domains.
        var variables: [CPVariable] = []
        variables.reserveCapacity(destroyed.count)
        for idx in destroyed {
            guard idx < genes.count else { continue }
            let gene = genes[idx]
            let candidateSlots = candidateStartTimes(
                duration: gene.duration,
                horizon: horizon,
                workStart: workStart,
                workEnd: workEnd,
                calendar: cal,
                preferred: gene.startTime
            )
            guard !candidateSlots.isEmpty else { return nil }
            variables.append(CPVariable(
                geneIndex: idx,
                domain: candidateSlots,
                duration: gene.duration
            ))
        }

        // Precedence: pull from movableEvents.dependsOn, restricted
        // to (a, b) pairs where both are in the destroyed window.
        let destroyedIDs = Set(destroyed.compactMap { idx -> String? in
            guard idx < genes.count else { return nil }
            return genes[idx].eventId
        })
        var precedence: [(Int, Int)] = []
        let idToIdx: [String: Int] = Dictionary(
            uniqueKeysWithValues: destroyed.compactMap { idx -> (String, Int)? in
                guard idx < genes.count else { return nil }
                return (genes[idx].eventId, idx)
            }
        )
        for event in context.movableEvents where destroyedIDs.contains(event.id) {
            for dep in event.dependsOn where destroyedIDs.contains(dep) {
                if let depIdx = idToIdx[dep], let selfIdx = idToIdx[event.id] {
                    precedence.append((depIdx, selfIdx))
                }
            }
        }

        // Fixed blocks: every fixed event + every non-destroyed gene.
        var fixedBlocks: [(start: Date, end: Date)] = context.fixedEvents.map {
            ($0.startDate, $0.endDate)
        }
        let destroyedSet = Set(destroyed)
        for (i, gene) in genes.enumerated() where !destroyedSet.contains(i) && gene.isIncluded {
            fixedBlocks.append((gene.startTime, gene.endTime))
        }

        // Score: maximise (− total displacement). Higher = better,
        // and the adapter calls argmax.
        let originalStarts: [Int: Date] = Dictionary(
            uniqueKeysWithValues: destroyed.compactMap { idx -> (Int, Date)? in
                guard idx < genes.count else { return nil }
                return (idx, genes[idx].startTime)
            }
        )
        let scoreClosure: (_ assignment: [Int: Date]) -> Double = { assignment in
            var displacement = 0.0
            for (idx, slot) in assignment {
                guard let original = originalStarts[idx] else { continue }
                displacement += abs(slot.timeIntervalSince(original))
            }
            return -displacement
        }

        let solution = repairer.solve(
            variables: variables,
            precedence: precedence,
            fixedBlocks: fixedBlocks,
            scoreAssignment: scoreClosure
        )
        guard !solution.assignments.isEmpty else { return nil }

        var mutated = IndexSet()
        for (idx, slot) in solution.assignments {
            guard idx < genes.count else { continue }
            genes[idx] = genes[idx].withSlot(nearest: slot, registry: slotRegistry)
            mutated.insert(idx)
        }
        return mutated
    }

    /// Generate candidate start times for one gene, sorted by
    /// distance from `preferred`. 30-minute resolution; bounded to
    /// the working-hours window of every horizon day.
    private func candidateStartTimes(
        duration: TimeInterval,
        horizon: DateInterval,
        workStart: Int,
        workEnd: Int,
        calendar: Calendar,
        preferred: Date
    ) -> [Date] {
        let resolution: TimeInterval = 30 * 60
        var slots: [Date] = []
        var dayCursor = calendar.startOfDay(for: horizon.start)
        let lastDay = calendar.startOfDay(for: horizon.end)
        while dayCursor <= lastDay {
            guard let dayStart = calendar.date(
                bySettingHour: workStart, minute: 0, second: 0, of: dayCursor
            ), let dayEnd = calendar.date(
                bySettingHour: workEnd, minute: 0, second: 0, of: dayCursor
            ) else {
                if let next = calendar.date(byAdding: .day, value: 1, to: dayCursor) {
                    dayCursor = next
                } else {
                    break
                }
                continue
            }
            var t = dayStart
            while t.addingTimeInterval(duration) <= dayEnd {
                if t >= horizon.start && t.addingTimeInterval(duration) <= horizon.end {
                    slots.append(t)
                }
                t = t.addingTimeInterval(resolution)
            }
            if let next = calendar.date(byAdding: .day, value: 1, to: dayCursor) {
                dayCursor = next
            } else {
                break
            }
        }
        // Sort by closeness to preferred slot (locality bias).
        slots.sort {
            abs($0.timeIntervalSince(preferred)) < abs($1.timeIntervalSince(preferred))
        }
        // Cap at a reasonable per-variable domain (large domains are
        // wasteful for the solver).
        if slots.count > 32 { slots = Array(slots.prefix(32)) }
        return slots
    }

}
