import Foundation

// MARK: - ScheduleChromosome regret-based repair
//
// Fallback path for cpRepair when the budget runs out without
// finding a complete assignment. Extracted from Chromosome+CPSATRepair.swift.

extension ScheduleChromosome {


    /// Regret-based insertion under topological precedence.
    ///
    /// Fallback path for `cpRepair` when the BnB budget runs out without
    /// finding any complete assignment. Builds a ready queue of destroyed
    /// genes whose prerequisites have all been re-placed, computes each
    /// gene's earliest and latest feasible slot, and places the tightest
    /// (smallest window) first at its earliest slot. Placement unlocks
    /// any dependents.
    ///
    /// Reverse-dependency deadlines (destroyed predecessor of a
    /// still-placed dependent) are folded into the per-gene `deadline`
    /// override so `findFirstFreeSlot` enforces them without new
    /// parameters.
    ///
    /// Residual dependency cycles (data bug) short-circuit: if the ready
    /// queue empties while destroyed genes remain unplaced, we append the
    /// rest in priority order — same fallback as `topoOrderedIndices`.
    // Internal (was `private`) — called from `applyLNS(...)` in
    // `Chromosome+Mutation.swift` as a fallback when `cpRepair` runs
    // out of budget.
    mutating func regretRepair(
        destroyed: Set<Int>,
        context: OptimizerContext
    ) -> IndexSet? {
        let cal = context.calendar
        let horizon = context.planningHorizon
        let slotRegistry = context.ensureSlotRegistry()

        var occupied: [(start: Date, end: Date)] = context.fixedEvents.map {
            ($0.startDate, $0.endDate)
        }
        for (j, gene) in genes.enumerated() where gene.isIncluded && !destroyed.contains(j) {
            occupied.append((gene.startTime, gene.endTime))
        }
        occupied.sort { $0.start < $1.start }
        occupied.reserveCapacity(occupied.count + destroyed.count)

        // See `repair()` for the rationale — binary-search insertion
        // keeps the per-placement cost O(log N + N) instead of the
        // full O(N log N) sort that used to run after every append.
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

        let eventById: [String: OptimizableEvent] = Dictionary(
            uniqueKeysWithValues: context.movableEvents.map { ($0.id, $0) }
        )
        let genesByEvent: [String: Int] = Dictionary(
            uniqueKeysWithValues: genes.enumerated().map { ($1.eventId, $0) }
        )

        // Topological in-degree over the destroyed subset only.
        // Dependencies satisfied by non-destroyed predecessors are
        // already reflected in `occupied`.
        var inDegree: [Int: Int] = [:]
        var destroyedDependents: [Int: [Int]] = [:]
        for i in destroyed { inDegree[i] = 0 }
        for i in destroyed {
            guard let event = eventById[genes[i].eventId] else { continue }
            for depId in event.dependsOn {
                if let depIdx = genesByEvent[depId], destroyed.contains(depIdx) {
                    destroyedDependents[depIdx, default: []].append(i)
                    inDegree[i, default: 0] += 1
                }
            }
        }

        // Reverse-dependency ceilings. If destroyed gene Y has a
        // non-destroyed dependent X already placed at startTime T, Y must
        // finish by T.
        var reverseDeadline: [Int: Date] = [:]
        for (j, g) in genes.enumerated() where g.isIncluded && !destroyed.contains(j) {
            guard let ev = eventById[g.eventId] else { continue }
            for depId in ev.dependsOn {
                guard let depIdx = genesByEvent[depId], destroyed.contains(depIdx) else { continue }
                let cur = reverseDeadline[depIdx] ?? .distantFuture
                if g.startTime < cur { reverseDeadline[depIdx] = g.startTime }
            }
        }

        var ready = Set(destroyed.filter { (inDegree[$0] ?? 0) == 0 })
        var changed = IndexSet()

        while !ready.isEmpty {
            // Regret pass: for every ready gene, compute earliest slot
            // (primary placement) and latest slot (window ceiling). The
            // gene with the smallest earliest↔latest window goes first.
            var best: (idx: Int, slot: Date, window: TimeInterval)? = nil
            var fallbackIdx: Int? = nil

            for idx in ready {
                let event = eventById[genes[idx].eventId]
                // Effective deadline = min(original, reverse-dep ceiling).
                // Kept inline rather than via nested function so there's no
                // ambiguity about self-capture in the mutating context.
                let origDL = event?.deadline
                let revDL = reverseDeadline[idx]
                let deadline: Date?
                if let o = origDL, let r = revDL { deadline = min(o, r) }
                else if let o = origDL { deadline = o }
                else if let r = revDL { deadline = r }
                else { deadline = nil }
                let earliest = Self.findFirstFreeSlot(
                    duration: genes[idx].duration,
                    preferredHours: event?.preferredHourRange,
                    occupied: occupied,
                    horizon: horizon,
                    workingHours: context.workingHours,
                    calendar: cal,
                    earliestStart: event?.earliestStart,
                    deadline: deadline,
                    dependsOn: event?.dependsOn ?? [],
                    placedGenes: genes,
                    genesByEvent: genesByEvent,
                    workingDays: context.preferences.workingDays,
                    eventId: event?.id,
                    context: context
                )
                guard let earliestSlot = earliest else {
                    if fallbackIdx == nil { fallbackIdx = idx }
                    continue
                }
                let latestSlot = Self.findLastFreeSlot(
                    duration: genes[idx].duration,
                    preferredHours: event?.preferredHourRange,
                    occupied: occupied,
                    horizon: horizon,
                    workingHours: context.workingHours,
                    calendar: cal,
                    earliestStart: event?.earliestStart,
                    deadline: deadline,
                    dependsOn: event?.dependsOn ?? [],
                    placedGenes: genes,
                    genesByEvent: genesByEvent,
                    workingDays: context.preferences.workingDays
                ) ?? earliestSlot

                let window = max(0, latestSlot.timeIntervalSince(earliestSlot))
                if let b = best {
                    // Smaller window = tighter = place first. Tie-break
                    // by priority desc so high-priority genes win head-
                    // to-head with same-tightness genes.
                    let windowTight = window < b.window
                    let windowTie = window == b.window
                    let higherPriority = genes[idx].priority > genes[b.idx].priority
                    if windowTight || (windowTie && higherPriority) {
                        best = (idx, earliestSlot, window)
                    }
                } else {
                    best = (idx, earliestSlot, window)
                }
            }

            let chosenIdx: Int
            let chosenSlot: Date?
            if let b = best {
                chosenIdx = b.idx
                chosenSlot = b.slot
            } else if let fb = fallbackIdx {
                chosenIdx = fb
                chosenSlot = nil
            } else {
                break
            }

            if let slot = chosenSlot {
                if genes[chosenIdx].startTime != slot {
                    genes[chosenIdx] = genes[chosenIdx].withSlot(nearest: slot, registry: slotRegistry)
                    changed.insert(chosenIdx)
                }
                insertSorted((slot, slot.addingTimeInterval(genes[chosenIdx].duration)))
            } else if genes[chosenIdx].isDroppable {
                if genes[chosenIdx].isIncluded {
                    genes[chosenIdx].isIncluded = false
                    changed.insert(chosenIdx)
                }
            }
            // else: non-droppable with no slot — leave in place; main
            // repair pass handles it.

            ready.remove(chosenIdx)
            for dep in destroyedDependents[chosenIdx] ?? [] {
                let next = (inDegree[dep] ?? 0) - 1
                inDegree[dep] = next
                if next == 0 { ready.insert(dep) }
            }
        }

        // Cycle fallback: any destroyed genes still carrying inDegree > 0
        // are part of a cycle. Place them in priority order without
        // precedence checks; `repair()` downstream will arbitrate.
        let stranded = destroyed.filter { (inDegree[$0] ?? 0) > 0 }
        if !stranded.isEmpty {
            let inPriorityOrder = stranded.sorted { genes[$0].priority > genes[$1].priority }
            for idx in inPriorityOrder {
                let event = eventById[genes[idx].eventId]
                let slot = Self.findFirstFreeSlot(
                    duration: genes[idx].duration,
                    preferredHours: event?.preferredHourRange,
                    occupied: occupied,
                    horizon: horizon,
                    workingHours: context.workingHours,
                    calendar: cal,
                    earliestStart: event?.earliestStart,
                    deadline: event?.deadline,
                    dependsOn: [],
                    placedGenes: genes,
                    genesByEvent: genesByEvent,
                    workingDays: context.preferences.workingDays,
                    eventId: event?.id,
                    context: context
                )
                if let slot {
                    if genes[idx].startTime != slot {
                        genes[idx] = genes[idx].withSlot(nearest: slot, registry: slotRegistry)
                        changed.insert(idx)
                    }
                    insertSorted((slot, slot.addingTimeInterval(genes[idx].duration)))
                }
            }
        }

        return changed.isEmpty ? nil : changed
    }

}
