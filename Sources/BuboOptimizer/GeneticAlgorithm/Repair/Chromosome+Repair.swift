import Foundation
import BuboDomain

// MARK: - ScheduleChromosome guided helpers + post-mutation repair
//
// Two coupled concerns extracted together because they share the
// `findNearestFreeSlot(...)` helper:
//
//   • Guided Mutation Helpers — `collectOccupiedIntervals(...)` and
//     `findNearestFreeSlot(...)`, used by the Mutation section in
//     `Chromosome.swift` to land guided moves on feasible ground.
//   • Repair — the post-mutation cleanup pass that fixes overlap with
//     fixed events, ordering violations on the dependency DAG, and
//     working-hours / working-days infractions. Calls
//     `findNearestFreeSlot(...)` for the relocation step and its own
//     private `topoOrderedIndices(...)` helper for the dependency
//     traversal.
//
// Extracted from `Chromosome.swift`; visibility changes:
//   • `collectOccupiedIntervals(...)` — was `private`, now internal so
//     `Chromosome.mutate(...)` still resolves it cross-file.
//   • `findNearestFreeSlot(...)` — was `private`, now internal for the
//     same reason (plus Repair below calls it from this same file).
//   • `topoOrderedIndices(...)` stays `private` here — called only by
//     `repair(...)` in this file.

public extension ScheduleChromosome {

    // MARK: - Guided Mutation Helpers

    /// Collect all occupied time intervals in the schedule, excluding gene at `excludeIndex`.
    ///
    /// Internal (was `private`) so this lives in `Chromosome+Repair.swift`
    /// while the Mutation section in `Chromosome.swift` still calls it.
    public func collectOccupiedIntervals(excluding excludeIndex: Int, context: OptimizerContext) -> [(start: Date, end: Date)] {
        var occupied: [(start: Date, end: Date)] = context.fixedEvents.map {
            ($0.startDate, $0.endDate)
        }
        for (j, gene) in genes.enumerated() where gene.isIncluded && j != excludeIndex {
            occupied.append((gene.startTime, gene.endTime))
        }
        occupied.sort { $0.start < $1.start }
        return occupied
    }

    /// Find the nearest free slot that can fit `duration`, searching outward from `near`.
    ///
    /// Internal (was `private`) — called from Mutation in `Chromosome.swift`
    /// and from Repair in this same file. Promoting beats duplicating the
    /// helper across both call sites.
    public func findNearestFreeSlot(
        near: Date,
        duration: TimeInterval,
        occupied: [(start: Date, end: Date)],
        workingHours: ClosedRange<Int>,
        horizon: DateInterval,
        calendar: Calendar,
        floor: Date,
        workingDays: Set<Int> = []
    ) -> Date? {
        // Search forward and backward from current position, try gap between each pair
        var candidates: [(start: Date, distance: TimeInterval)] = []

        // Build sorted occupied list within horizon
        let sorted = occupied.filter { $0.end > horizon.start && $0.start < horizon.end }

        // Reject a candidate start that lands on a non-working day when
        // `workingDays` is set. Keeps repair's relocation in lock-step
        // with the hard constraint — otherwise the "nearest free slot"
        // logic would happily park a conflicting gene on a day the
        // constraint will reject and call the repair done.
        func accept(_ start: Date) -> Bool {
            if workingDays.isEmpty { return true }
            let weekday = calendar.component(.weekday, from: start)
            return workingDays.contains(weekday)
        }

        // Scan gaps between occupied intervals
        var prevEnd = horizon.start
        for occ in sorted {
            let gapStart = max(prevEnd, floor)
            let gapEnd = occ.start
            if gapEnd.timeIntervalSince(gapStart) >= duration {
                var clamped = clampToWorkingHours(gapStart, duration: duration, workingHours: workingHours, calendar: calendar, floor: floor)
                if !workingDays.isEmpty {
                    clamped = advancePastNonWorkingDay(from: clamped, workingHours: workingHours, horizon: horizon, calendar: calendar, workingDays: workingDays)
                }
                if accept(clamped) && clamped.addingTimeInterval(duration) <= gapEnd {
                    candidates.append((clamped, abs(clamped.timeIntervalSince(near))))
                }
            }
            prevEnd = max(prevEnd, occ.end)
        }
        // Gap after last occupied
        let finalGapStart = max(prevEnd, floor)
        if horizon.end.timeIntervalSince(finalGapStart) >= duration {
            var clamped = clampToWorkingHours(finalGapStart, duration: duration, workingHours: workingHours, calendar: calendar, floor: floor)
            if !workingDays.isEmpty {
                clamped = advancePastNonWorkingDay(from: clamped, workingHours: workingHours, horizon: horizon, calendar: calendar, workingDays: workingDays)
            }
            if accept(clamped) && clamped.addingTimeInterval(duration) <= horizon.end {
                candidates.append((clamped, abs(clamped.timeIntervalSince(near))))
            }
        }

        // Return the closest candidate to original position
        return candidates.min(by: { $0.distance < $1.distance })?.start
    }

    // MARK: - Repair

    /// Fix hard constraint violations in-place:
    /// 1. Clamp all genes to working hours
    /// 2. Resolve overlaps by shifting conflicting genes to the nearest free slot
    /// 3. Enforce `dependsOn` ordering: a gene may only start after every one
    ///    of its (included) prerequisites has finished.
    public mutating func repair(context: OptimizerContext) {
        // Repair moves genes; invalidate cached features.
        cachedFeatures = nil

        let cal = context.calendar
        let horizonStart = context.planningHorizon.start
        let workingDays = context.preferences.workingDays
        let prefs = context.preferences
        let slotRegistry = context.ensureSlotRegistry()

        // Pass 1: Clamp to working hours and planning horizon. When the
        // user configured `workingDays`, rehome non-working-day
        // placements onto the next in-horizon working day first —
        // otherwise `clampToWorkingHours` would leave the event on
        // Saturday (just inside 9–18), which the
        // WorkingHoursConstraint would then reject every generation
        // until a mutation happened to flip it onto a working day.
        // Without this, the day-aware seeders upstream get silently
        // undone by repair as soon as mutation pushes anything around.
        for i in genes.indices where genes[i].isIncluded {
            let event = context.movableEvents.first { $0.id == genes[i].eventId }
            let earliest = event?.earliestStart
            let floor = [horizonStart, earliest].compactMap { $0 }.max() ?? horizonStart

            var target = genes[i].startTime
            if !prefs.isWorkingDay(target, calendar: cal) {
                target = advancePastNonWorkingDay(
                    from: target,
                    workingHours: context.workingHours,
                    horizon: context.planningHorizon,
                    calendar: cal,
                    workingDays: workingDays
                )
            }

            let clamped = clampToWorkingHours(target, duration: genes[i].duration, workingHours: context.workingHours, calendar: cal, floor: floor)
            genes[i] = genes[i].withSlot(nearest: clamped, registry: slotRegistry)
        }

        // Pass 2: Resolve overlaps. We visit genes in topological order
        // (prerequisites before dependents) so a dependent's overlap check
        // observes already-placed prerequisites; ties broken by priority
        // descending so high-priority tasks still keep their slots when no
        // dependency edge dictates order. Cycles degrade gracefully: nodes
        // left in the work list after Kahn's algorithm finishes get appended
        // in priority order, preserving the pre-topological behaviour.
        let sortedIndices = topoOrderedIndices(context: context)

        var occupied: [(start: Date, end: Date)] = context.fixedEvents.map {
            ($0.startDate, $0.endDate)
        }
        occupied.sort { $0.start < $1.start }
        occupied.reserveCapacity(occupied.count + sortedIndices.count)

        // Insert `entry` into the already-sorted `occupied` array in
        // O(log N) binary search + O(N) shift. Kept inline so the
        // iteration below stays easy to follow.
        //
        // Previously this loop appended and then ran a full O(N log N)
        // `sort` on every iteration — O(N² log N) total when repair
        // touches all N genes, which is the hot path for any mutation.
        // A linear scan would work for tiny arrays, but binary search
        // keeps the insertion cost bounded as the horizon grows to
        // include dozens of fixed events + movables.
        func insertSorted(_ entry: (start: Date, end: Date)) {
            var lo = 0
            var hi = occupied.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if occupied[mid].start < entry.start {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            occupied.insert(entry, at: lo)
        }

        for idx in sortedIndices {
            let gene = genes[idx]
            let event = context.movableEvents.first { $0.id == gene.eventId }
            let earliest = event?.earliestStart
            var floor = [horizonStart, earliest].compactMap { $0 }.max() ?? horizonStart

            // Dependency floor: this gene may not start before any of its
            // included prerequisites has finished. Because we iterate in
            // topological order, every prerequisite has already been placed
            // in its final slot for this repair pass.
            if let event, !event.dependsOn.isEmpty {
                for depId in event.dependsOn {
                    if let depGene = genes.first(where: { $0.eventId == depId && $0.isIncluded }) {
                        floor = max(floor, depGene.endTime)
                    }
                }
            }

            // If the current slot is either before the dependency floor or
            // overlaps an occupied interval, relocate to the nearest valid gap.
            let beforeFloor = gene.startTime < floor
            let hasOverlap = occupied.contains { occ in
                gene.startTime < occ.end && gene.endTime > occ.start
            }

            // Non-working-day-resident genes also need relocation even
            // when they're already within working hours and
            // conflict-free — the WorkingHoursConstraint otherwise
            // flags them every generation. Detecting here (rather than
            // always in Pass 1) avoids a redundant relocate when the
            // gene was already moved to a working day earlier in this
            // repair.
            let onNonWorkingDay = !prefs.isWorkingDay(gene.startTime, calendar: cal)

            if beforeFloor || hasOverlap || onNonWorkingDay {
                if let freeStart = findNearestFreeSlot(
                    near: max(gene.startTime, floor),
                    duration: gene.duration,
                    occupied: occupied,
                    workingHours: context.workingHours,
                    horizon: context.planningHorizon,
                    calendar: cal,
                    floor: floor,
                    workingDays: workingDays
                ) {
                    genes[idx] = gene.withSlot(nearest: freeStart, registry: slotRegistry)
                } else if beforeFloor {
                    // No gap fits but dependency floor was violated — at least
                    // honour the floor; this may still overlap, which leaves
                    // the ConstraintEngine to penalise rather than failing
                    // the whole repair silently.
                    var fallback = floor
                    if !prefs.isWorkingDay(fallback, calendar: cal) {
                        fallback = advancePastNonWorkingDay(
                            from: fallback,
                            workingHours: context.workingHours,
                            horizon: context.planningHorizon,
                            calendar: cal,
                            workingDays: workingDays
                        )
                    }
                    let fallbackClamped = clampToWorkingHours(fallback, duration: gene.duration,
                                                              workingHours: context.workingHours,
                                                              calendar: cal, floor: floor)
                    genes[idx] = gene.withSlot(nearest: fallbackClamped, registry: slotRegistry)
                }
            }

            insertSorted((genes[idx].startTime, genes[idx].endTime))
        }

        // Canonicalize equivalent gene groups after
        // structural repair. Stable sort makes the cache fingerprint
        // robust to order-preserving mutations. Safe to run
        // unconditionally — no-op when the order is already canonical.
        SymmetryBreaker.canonicalize(&self)

        needsEvaluation = true
        // Repair may have moved genes; fitness reflects the previous
        // layout. Mark phantom until the next real evaluation.
        isFitnessReal = false

        // Post-repair invariant check (DEBUG). Every active gene must
        // be on a working day and its slotIndex (if set) must resolve
        // to its startTime. A hit here means repair failed to enforce
        // what it's supposed to enforce — a bug worth seeing.
        #if DEBUG
        for gene in genes where gene.isIncluded {
            GADebugLog.assertWorkingDay(gene, preferences: context.preferences, calendar: cal, site: "repair")
            GADebugLog.assertSlotBinding(gene, registry: slotRegistry, site: "repair")
        }
        #endif
    }

    /// Kahn's algorithm on the `dependsOn` graph among included genes, with
    /// ties broken by priority descending. Returns every included gene's
    /// index exactly once: prerequisites first, then dependents. Dependencies
    /// on excluded/absent genes are ignored (they can't influence timing).
    /// Cycles leave some indices unvisited; those are appended at the end in
    /// priority order so repair behaviour on malformed graphs matches the
    /// pre-topological version.
    private func topoOrderedIndices(context: OptimizerContext) -> [Int] {
        let includedIndices = genes.indices.filter { genes[$0].isIncluded }
        guard !includedIndices.isEmpty else { return [] }

        // Map eventId → gene index for O(1) lookup during edge construction.
        var indexByEventId: [String: Int] = [:]
        indexByEventId.reserveCapacity(includedIndices.count)
        for i in includedIndices { indexByEventId[genes[i].eventId] = i }

        // Pre-compute inDegrees and adjacency (dependency → dependent edges).
        var inDegree: [Int: Int] = [:]
        var adjacency: [Int: [Int]] = [:]
        for i in includedIndices { inDegree[i] = 0 }

        let eventById: [String: OptimizableEvent] = Dictionary(
            uniqueKeysWithValues: context.movableEvents.map { ($0.id, $0) }
        )

        for i in includedIndices {
            guard let event = eventById[genes[i].eventId] else { continue }
            for depId in event.dependsOn {
                // Only count dependencies on included genes present in this
                // chromosome. Excluded or missing prerequisites don't impose
                // a scheduling order.
                if let depIdx = indexByEventId[depId] {
                    adjacency[depIdx, default: []].append(i)
                    inDegree[i, default: 0] += 1
                }
            }
        }

        // Kahn's algorithm with a priority-ordered ready queue. A plain queue
        // would be topologically valid but arbitrary on ties; using priority
        // preserves the "important gene first" behaviour of the previous
        // overlap-resolution pass.
        var ready = includedIndices
            .filter { (inDegree[$0] ?? 0) == 0 }
            .sorted { genes[$0].priority > genes[$1].priority }
        var result: [Int] = []
        result.reserveCapacity(includedIndices.count)

        while !ready.isEmpty {
            // Always pop the highest-priority ready node. Linear scan is fine
            // here because `ready` stays small relative to population sizes.
            let head = ready.removeFirst()
            result.append(head)
            for dependent in adjacency[head] ?? [] {
                let next = (inDegree[dependent] ?? 0) - 1
                inDegree[dependent] = next
                if next == 0 {
                    // Insert keeping ready sorted by priority descending.
                    let insertAt = ready.firstIndex { genes[$0].priority < genes[dependent].priority } ?? ready.count
                    ready.insert(dependent, at: insertAt)
                }
            }
        }

        // Any indices still with inDegree > 0 are part of a cycle. Append them
        // in priority order so repair still has something to iterate over —
        // cycles are a data-integrity bug but shouldn't crash the optimizer.
        let visited = Set(result)
        let leftovers = includedIndices
            .filter { !visited.contains($0) }
            .sorted { genes[$0].priority > genes[$1].priority }
        result.append(contentsOf: leftovers)
        return result
    }

}
