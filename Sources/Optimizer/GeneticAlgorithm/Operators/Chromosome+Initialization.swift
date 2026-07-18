import Foundation
import BuboDomain

// MARK: - ScheduleChromosome initialization
//
// Three seeding paths the GA's initial population draws from:
//
//   • `random(context:)`       — uniform-ish placement with droppable-
//                                rate tied to the week's saturation.
//                                Returns a chromosome with feasible
//                                placements but no guarantee of
//                                inter-event harmony — that's the GA's
//                                job to find.
//   • `greedy(context:)`       — single-pass priority-first placement.
//   • `greedy(context:variantIndex:)`
//   • `greedyWithOrder(context:order:)` — multi-strategy variant
//                                seeding (priority-first, deadline-
//                                first, duration-first, etc.) used by
//                                `createInitialPopulation` so seeded
//                                individuals don't collapse to a
//                                single basin.
//
// Plus the private helpers `randomStartTime(...)` and
// `fixedSaturation(...)` from the original "Helpers" section, both
// only used by the initialisation paths.
//
// Extracted from `Chromosome.swift` so the seeding logic lives in its
// own file separate from the much larger mutation / CP-SAT-repair /
// repair bulk. Visibility: `findFirstFreeSlot(...)` in `Chromosome.swift`
// dropped its `private` modifier so this file can call it.

public extension ScheduleChromosome {

    // MARK: - Random Initialization

    static func random(context: OptimizerContext) -> ScheduleChromosome {
        let cal = context.calendar
        // Feasibility-guided droppable inclusion rate: when the week is
        // already packed (fixed events eat most of the working hours),
        // the 70% flat rate produces mostly-infeasible starting
        // individuals that the GA has to spend generations repairing.
        // Drop the rate proportional to the week's saturation so tight
        // weeks start with fewer optimistic inclusions and loose weeks
        // keep the old exploration behaviour.
        let saturation = Self.fixedSaturation(context: context)
        let dropInclusionRate = max(0.35, 0.85 - 0.6 * saturation)
        let workingDays = context.preferences.workingDays

        // Randomised-greedy placement. We shuffle the event list so
        // each `random()` call explores a different insertion order,
        // then place every included event into the first working-day
        // slot that fits — `findFirstFreeSlot` already filters
        // working-days, working-hours, horizon, deadlines, and prior
        // placements. The result is orders of magnitude closer to
        // feasibility than a naive `randomStartTime` jitter (which
        // ignored overlap entirely), so repair's Pass 1/2 has less
        // cleanup to do and the GA spends its generation budget on
        // soft-objective polish instead of repairing overlaps it
        // could have avoided at birth.
        //
        // Droppable genes that don't fit are probabilistically
        // excluded instead of deterministically dropped — unlike
        // `greedyWithOrder`, which is deterministic. We still want
        // some droppables in unusual slots to preserve diversity.
        let shuffled = context.rng.shuffled(context.movableEvents)
        var genes: [ScheduleGene] = []
        genes.reserveCapacity(shuffled.count)
        var occupied: [(start: Date, end: Date)] = context.fixedEvents.map {
            ($0.startDate, $0.endDate)
        }
        let genesByEventOrder: [String: Int] = Dictionary(
            uniqueKeysWithValues: shuffled.enumerated().map { ($1.id, $0) }
        )
        // Slot registry for the discrete index binding. `findFirstFreeSlot`
        // and `randomStartTime` both return aligned `Date`s, so a binary
        // search reliably maps the result back to its registry index.
        // When the registry is empty (tests, degenerate horizon) we
        // leave `slotIndex` nil and the gene reads as "no slot binding".
        let slotRegistry = context.ensureSlotRegistry()

        for event in shuffled {
            // GRASP-style slot choice: sample a handful of random
            // candidates from the event's precomputed feasible
            // domain and keep the first that doesn't collide with
            // anything already placed. Insertion-order shuffling
            // alone gives zero diversity for small workloads — with
            // a single movable event, pure first-fit made every
            // `random()` individual an identical clone and the
            // initial population collapsed to one point. The domain
            // already excludes working-hour, working-day, horizon,
            // earliest-start, and deadline violations, so a sampled
            // slot is exactly as feasible as a first-fit slot;
            // events with precedence edges skip the sampler because
            // only `findFirstFreeSlot` sees the dependency DAG, and
            // events with a preferred-hour range skip it because the
            // domain doesn't encode that clamp.
            var slot: Date? = nil
            if event.dependsOn.isEmpty && event.preferredHourRange == nil {
                let domain = context.ensureSlotDomain(for: event.id)
                if !domain.isEmpty {
                    let duration = event.duration
                    sampling: for _ in 0..<4 {
                        let idx = domain.indices[context.rng.int(in: 0..<domain.indices.count)]
                        guard let candidate = slotRegistry.resolvedDate(at: idx) else { continue }
                        let candidateEnd = candidate.addingTimeInterval(duration)
                        for block in occupied where block.start < candidateEnd && candidate < block.end {
                            continue sampling
                        }
                        slot = candidate
                        break
                    }
                }
            }
            if slot == nil {
                slot = Self.findFirstFreeSlot(
                    duration: event.duration,
                    preferredHours: event.preferredHourRange,
                    occupied: occupied,
                    horizon: context.planningHorizon,
                    workingHours: context.workingHours,
                    calendar: cal,
                    earliestStart: event.earliestStart,
                    deadline: event.deadline,
                    dependsOn: event.dependsOn,
                    placedGenes: genes,
                    genesByEvent: genesByEventOrder,
                    workingDays: workingDays,
                    eventId: event.id,
                    context: context
                )
            }

            // Roll the saturation-aware inclusion decision for
            // droppables, then downgrade to excluded when the slot
            // search came up empty — better than over-promising an
            // unplaceable event and letting repair silently drop it.
            var included: Bool
            if event.isDroppable {
                let wanted = context.rng.bool(probability: dropInclusionRate)
                included = wanted && slot != nil
            } else {
                included = true
            }

            // When no slot fits but the event must ship (non-droppable
            // or droppable we chose to include), fall back to a random
            // working-day start so the chromosome still has a value;
            // constraint penalties + repair will arbitrate.
            let rawStart = slot ?? randomStartTime(
                for: event,
                in: context.planningHorizon,
                workingHours: context.workingHours,
                calendar: cal,
                rng: context.rng,
                workingDays: workingDays
            )

            // Align seed startTime to the registry grid. Callers
            // above (`findFirstFreeSlot`, `randomStartTime`) can
            // return off-grid Dates when floors like `horizon.start`
            // carry the current wall-clock time or when gaps abut
            // fixed-event boundaries at sub-minute precision. Snapping
            // keeps invariant (1) — `startTime == registry.slots[slotIndex]`.
            let boundSlot = slotRegistry.nearestIndex(to: rawStart)
            let start = boundSlot.flatMap { slotRegistry.resolvedDate(at: $0) } ?? rawStart
            genes.append(ScheduleGene(
                eventId: event.id,
                title: event.title,
                startTime: start,
                duration: event.duration,
                context: event.context,
                energyCost: event.energyCost,
                priority: event.priority,
                isFocusBlock: event.isFocusBlock,
                storyPoints: event.storyPoints,
                isDroppable: event.isDroppable,
                isIncluded: included,
                pomodoroConfig: event.pomodoroConfig,
                reservedTaskIds: event.reservedTaskIds,
                groupId: event.groupId,
                slotIndex: boundSlot
            ))
            if included {
                occupied.append((start, start.addingTimeInterval(event.duration)))
                occupied.sort { $0.start < $1.start }
            }
        }

        // Restore canonical (movableEvents) order so downstream code
        // keyed on gene index behaves identically to the prior random
        // implementation — only startTime/isIncluded are different.
        let geneByEvent = Dictionary(genes.map { ($0.eventId, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = context.movableEvents.compactMap { geneByEvent[$0.id] }
        return ScheduleChromosome(genes: ordered, needsEvaluation: true)
    }

    // MARK: - Greedy Initialization

    /// Build a feasible chromosome by greedily placing events one at
    /// a time into the first available slot.
    ///
    /// Sort key: `(priority DESC, backlogIndex ASC, deadline ASC)`.
    /// Matches exactly what `BacklogOrderObjective` rewards, so the
    /// greedy seed starts at a BacklogOrder score of 1.0 and the GA
    /// only has to polish the spacing / energy-curve axes — not
    /// discover the right permutation from a random shuffle.
    /// `backlogIndex` sits between priority and deadline so the
    /// user's drag order breaks priority ties before deadlines do
    /// (deadline ties are rare in practice and less user-visible).
    /// Events without a `backlogIndex` sink to the end of their
    /// priority tier.
    static func greedy(context: OptimizerContext) -> ScheduleChromosome {
        greedy(context: context, variantIndex: 0)
    }

    /// Multi-strategy greedy seeder. `variantIndex % 4` selects the
    /// sort key, so a population-level seed loop with `0..<greedyCount`
    /// exercises four qualitatively-different insertion orders
    /// instead of N identical copies of the default:
    ///
    ///   0. Priority + backlog (default) — rewards exactly what
    ///      `BacklogOrderObjective` scores.
    ///   1. Urgency-first: deadline ASC, priority DESC tiebreaker.
    ///      Finds a feasible layout when tight deadlines dominate.
    ///   2. Short-first: duration ASC, priority DESC tiebreaker.
    ///      Classic bin-packing intuition — small items slot into
    ///      gaps that bigger ones would force onto another day.
    ///   3. Long-first: duration DESC, priority DESC tiebreaker.
    ///      Reserves big uninterrupted blocks before short tasks
    ///      fragment the day; helps when focus blocks matter.
    ///
    /// Each island's greedy seeds cycle through these so the first
    /// generation already spans four basins in parallel. The GA's
    /// crossover then mixes them, which is far cheaper than
    /// rediscovering each ordering from random shuffles.
    static func greedy(context: OptimizerContext, variantIndex: Int) -> ScheduleChromosome {
        let backlogById = context.backlogIndexMap()
        let strategy = ((variantIndex % 4) + 4) % 4

        let sortedEvents: [OptimizableEvent]
        switch strategy {
        case 1:
            // Deadline ASC, priority DESC, backlog ASC.
            sortedEvents = context.movableEvents.sorted { a, b in
                switch (a.deadline, b.deadline) {
                case let (da?, db?) where da != db: return da < db
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
                if a.priority != b.priority { return a.priority > b.priority }
                let ai = backlogById[a.id] ?? Int.max
                let bi = backlogById[b.id] ?? Int.max
                return ai < bi
            }
        case 2:
            // Duration ASC, priority DESC, backlog ASC.
            sortedEvents = context.movableEvents.sorted { a, b in
                if a.duration != b.duration { return a.duration < b.duration }
                if a.priority != b.priority { return a.priority > b.priority }
                let ai = backlogById[a.id] ?? Int.max
                let bi = backlogById[b.id] ?? Int.max
                return ai < bi
            }
        case 3:
            // Duration DESC, priority DESC, backlog ASC.
            sortedEvents = context.movableEvents.sorted { a, b in
                if a.duration != b.duration { return a.duration > b.duration }
                if a.priority != b.priority { return a.priority > b.priority }
                let ai = backlogById[a.id] ?? Int.max
                let bi = backlogById[b.id] ?? Int.max
                return ai < bi
            }
        default:
            // Priority DESC, backlog ASC, deadline ASC — matches
            // `BacklogOrderObjective` by construction.
            sortedEvents = context.movableEvents.sorted { a, b in
                if a.priority != b.priority { return a.priority > b.priority }
                let ai = backlogById[a.id]
                let bi = backlogById[b.id]
                if ai != bi {
                    switch (ai, bi) {
                    case let (l?, r?): return l < r
                    case (_?, nil):    return true
                    case (nil, _?):    return false
                    default:           break
                    }
                }
                if let da = a.deadline, let db = b.deadline, da != db { return da < db }
                if (a.deadline != nil) != (b.deadline != nil) { return a.deadline != nil }
                return false
            }
        }
        return greedyWithOrder(context: context, eventsInPlacementOrder: sortedEvents)
    }

    /// Build a feasible chromosome by placing events in the caller-
    /// supplied order. Used by the brute-force fast path
    /// (`BuboOptimizer` generates every permutation for tiny backlogs
    /// and picks the best by fitness) and by warm-start builders that
    /// want to inject a learned priority order.
    ///
    /// `eventsInPlacementOrder` *must* contain every event in
    /// `context.movableEvents` — duplicates or omissions leave the
    /// returned chromosome partially unscheduled and are the caller's
    /// bug, not this function's.
    static func greedyWithOrder(
        context: OptimizerContext,
        eventsInPlacementOrder sortedEvents: [OptimizableEvent]
    ) -> ScheduleChromosome {
        let cal = context.calendar
        let workingDays = context.preferences.workingDays
        let slotRegistry = context.ensureSlotRegistry()

        // Collect occupied intervals (from fixed events)
        var occupied: [(start: Date, end: Date)] = context.fixedEvents.map {
            ($0.startDate, $0.endDate)
        }

        var genes: [ScheduleGene] = []
        let genesByEvent: [String: Int] = Dictionary(
            uniqueKeysWithValues: sortedEvents.enumerated().map { ($1.id, $0) }
        )

        for event in sortedEvents {
            let slot = findFirstFreeSlot(
                duration: event.duration,
                preferredHours: event.preferredHourRange,
                occupied: occupied,
                horizon: context.planningHorizon,
                workingHours: context.workingHours,
                calendar: cal,
                earliestStart: event.earliestStart,
                deadline: event.deadline,
                dependsOn: event.dependsOn,
                placedGenes: genes,
                genesByEvent: genesByEvent,
                workingDays: workingDays,
                eventId: event.id,
                context: context
            )

            let isIncluded: Bool
            if slot != nil {
                isIncluded = true
            } else {
                isIncluded = !event.isDroppable
            }

            let rawStart = slot ?? randomStartTime(
                for: event,
                in: context.planningHorizon,
                workingHours: context.workingHours,
                calendar: cal,
                rng: context.rng,
                workingDays: workingDays
            )
            // Snap to registry grid — see `random(context:)` above.
            let boundSlot = slotRegistry.nearestIndex(to: rawStart)
            let startTime = boundSlot.flatMap { slotRegistry.resolvedDate(at: $0) } ?? rawStart

            let gene = ScheduleGene(
                eventId: event.id,
                title: event.title,
                startTime: startTime,
                duration: event.duration,
                context: event.context,
                energyCost: event.energyCost,
                priority: event.priority,
                isFocusBlock: event.isFocusBlock,
                storyPoints: event.storyPoints,
                isDroppable: event.isDroppable,
                isIncluded: isIncluded,
                pomodoroConfig: event.pomodoroConfig,
                reservedTaskIds: event.reservedTaskIds,
                groupId: event.groupId,
                slotIndex: boundSlot
            )
            genes.append(gene)

            if isIncluded {
                occupied.append((startTime, startTime.addingTimeInterval(event.duration)))
                occupied.sort { $0.start < $1.start }
            }
        }

        // Restore original event order (genes indexed by movableEvents order)
        let geneMap = Dictionary(genes.map { ($0.eventId, $0) }, uniquingKeysWith: { first, _ in first })
        let orderedGenes = context.movableEvents.compactMap { event in
            geneMap[event.id]
        }

        // Fallback: if compactMap dropped any (shouldn't happen), fill with random
        var result = orderedGenes
        let missing = context.movableEvents.filter { ev in !result.contains(where: { $0.eventId == ev.id }) }
        for event in missing {
            let rawStart = randomStartTime(for: event, in: context.planningHorizon, workingHours: context.workingHours, calendar: cal, rng: context.rng, workingDays: workingDays)
            let boundSlot = slotRegistry.nearestIndex(to: rawStart)
            let start = boundSlot.flatMap { slotRegistry.resolvedDate(at: $0) } ?? rawStart
            result.append(ScheduleGene(
                eventId: event.id, title: event.title, startTime: start,
                duration: event.duration, context: event.context, energyCost: event.energyCost,
                priority: event.priority, isFocusBlock: event.isFocusBlock,
                storyPoints: event.storyPoints, isDroppable: event.isDroppable, isIncluded: !event.isDroppable,
                pomodoroConfig: event.pomodoroConfig,
                reservedTaskIds: event.reservedTaskIds,
                groupId: event.groupId,
                slotIndex: boundSlot
            ))
        }

        return ScheduleChromosome(genes: result, needsEvaluation: true)
    }

    // MARK: - Helpers

    private static func randomStartTime(
        for event: OptimizableEvent,
        in horizon: DateInterval,
        workingHours: ClosedRange<Int>,
        calendar: Calendar,
        rng: GARandom,
        workingDays: Set<Int> = []
    ) -> Date {
        // Count distinct calendar days spanned (not whole 24h periods) so
        // the GA can reach every day in the horizon, even when the start is
        // mid-afternoon and the horizon overflows into the next day.
        let horizonStartDay = calendar.startOfDay(for: horizon.start)
        let horizonLastDay = calendar.startOfDay(for: horizon.end.addingTimeInterval(-1))
        let daysInHorizon = max(1, (calendar.dateComponents([.day], from: horizonStartDay, to: horizonLastDay).day ?? 0) + 1)

        let hourRange = event.preferredHourRange ?? workingHours
        // Round up: a 90-min task needs two full hours of runway. Truncation
        // here (`Int(1.5) == 1`) let the sampler start a task at
        // `workEnd - 1h`, pushing its end past working hours and tripping
        // the WorkingHours hard constraint.
        let durationHours = Int((event.duration / 3600).rounded(.up))
        let maxStartHour = max(hourRange.lowerBound, hourRange.upperBound - durationHours)
        let floor = [horizon.start, event.earliestStart].compactMap { $0 }.max() ?? horizon.start

        // Compute the earliest feasible start on a given day offset, or nil
        // when no 15-minute slot between `floor` and `maxStartHour` exists
        // on that day. Keeps today (offset 0) usable when horizon.start is
        // mid-afternoon, but skips it entirely when the floor is already
        // past the last feasible starting hour. Non-working days return
        // nil too when `workingDays` is set — matches the hard-constraint
        // behaviour so the sampler doesn't seed placements that the
        // `WorkingHoursConstraint` will immediately reject.
        func earliestSlot(onOffset offset: Int) -> Date? {
            guard let day = calendar.date(byAdding: .day, value: offset, to: horizonStartDay) else {
                return nil
            }
            if !workingDays.isEmpty {
                let weekday = calendar.component(.weekday, from: day)
                if !workingDays.contains(weekday) { return nil }
            }
            guard let dayLower = calendar.date(bySettingHour: hourRange.lowerBound, minute: 0, second: 0, of: day),
                  let dayUpper = calendar.date(bySettingHour: maxStartHour, minute: 0, second: 0, of: day)
            else { return nil }
            let lower = max(dayLower, floor)
            return lower <= dayUpper ? lower : nil
        }

        // Pick a day that can host the event. Without this probe, a
        // `horizon.start` of (say) 17:30 would pin every `offset == 0`
        // draw to exactly `horizon.start` — after the old `bySettingHour`
        // then `max(result, horizon.start)` clamp — piling every random
        // seed's same-day placements onto a single instant. That stacked
        // conflict surface pushes the GA to either drop a task or shift
        // the first event to tomorrow even when later slots today fit.
        var dayOffset = rng.int(in: 0..<daysInHorizon)
        if earliestSlot(onOffset: dayOffset) == nil {
            var found: Int?
            for alt in 0..<daysInHorizon where earliestSlot(onOffset: alt) != nil {
                found = alt
                break
            }
            dayOffset = found ?? dayOffset
        }

        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: horizonStartDay),
              let dayLower = calendar.date(bySettingHour: hourRange.lowerBound, minute: 0, second: 0, of: day),
              let dayUpper = calendar.date(bySettingHour: maxStartHour, minute: 0, second: 0, of: day)
        else {
            return floor
        }

        let lower = max(dayLower, floor)
        // Sample uniformly in 15-minute steps across [lower, dayUpper]. When
        // the range collapses (e.g. no horizon day can host the event), we
        // fall through to `lower` — still at or after the floor.
        let slotSeconds: TimeInterval = 15 * 60
        let span = max(0, Int(dayUpper.timeIntervalSince(lower) / slotSeconds))
        let offset = rng.int(in: 0...span)
        return lower.addingTimeInterval(TimeInterval(offset) * slotSeconds)
    }

    /// Ratio in [0, 1] describing how much of the horizon's working hours are
    /// already committed to fixed events. Non-working days are excluded via
    /// `preferences.isWorkingDay(_:calendar:)` because those hours aren't
    /// available anyway. Used by `random(context:)` to decide how
    /// optimistic the droppable-gene inclusion rate should be: when the
    /// week is nearly full of meetings the GA shouldn't start out with
    /// every optional task flagged "include".
    private static func fixedSaturation(context: OptimizerContext) -> Double {
        let cal = context.calendar
        let prefs = context.preferences
        let horizon = context.planningHorizon
        let hoursPerDay = Double(context.workingHours.upperBound - context.workingHours.lowerBound)
        guard hoursPerDay > 0 else { return 0 }

        let startDay = cal.startOfDay(for: horizon.start)
        let lastDay = cal.startOfDay(for: horizon.end.addingTimeInterval(-1))
        let days = max(1, (cal.dateComponents([.day], from: startDay, to: lastDay).day ?? 0) + 1)

        var workingDayCount = 0
        for offset in 0..<days {
            guard let day = cal.date(byAdding: .day, value: offset, to: startDay) else { continue }
            if !prefs.isWorkingDay(day, calendar: cal) { continue }
            workingDayCount += 1
        }
        guard workingDayCount > 0 else { return 0 }

        let totalAvailableHours = Double(workingDayCount) * hoursPerDay
        let fixedHours = context.fixedEvents.reduce(0.0) { acc, ev in
            if !prefs.isWorkingDay(ev.startDate, calendar: cal) { return acc }
            return acc + ev.endDate.timeIntervalSince(ev.startDate) / 3600
        }
        return max(0, min(1, fixedHours / totalAvailableHours))
    }
}
