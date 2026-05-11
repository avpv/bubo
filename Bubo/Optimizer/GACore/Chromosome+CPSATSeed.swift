import Foundation

// MARK: - ScheduleChromosome CP-SAT seeding + shared slot helpers
//
// `cpSeeded(context:warmStart:)` — single-shot feasible seed produced
// by `CPSATRepairer`, the same CDCL-lite solver the LNS repair path
// uses. Considers all events jointly (jointly-feasible placement)
// instead of greedy's one-at-a-time pass, so a placement-order
// conflict gets backtracked instead of forcing a drop. Returns nil
// when the solver times out or when domain enumeration produces an
// empty set for any non-droppable gene; the caller falls back to
// greedy/random seeding (see `createInitialPopulation`).
//
// The file also owns the slot-search helpers shared with the LNS
// repair path:
//   • `findFirstFreeSlot(...)` — forward gap walk; used by seeding,
//     `random(...)`, `greedyWithOrder(...)`, and the LNS repair
//     bridge in `Chromosome+CPSATRepair.swift`.
//   • `findLastFreeSlot(...)` — backward gap walk, mirror semantics.
//   • `enumerateFeasibleSlots(...)` — multi-signal-scored domain
//     enumeration consumed by the BnB inner loop.
//   • `OccupiedInterval` — bookkeeping struct carrying enough metadata
//     (context, day) for the cpRepair signal proxies to score
//     candidates against participant clustering, break placement, and
//     week balance without re-walking the schedule.
//
// Extracted from `Chromosome.swift` so the entire CP-SAT subsystem
// (seeding + LNS repair) lives in two sibling files instead of one
// 2000-line monolith. No further visibility changes needed — the
// shared helpers were already promoted to internal in the prior
// `+CPSATRepair` extraction commit.

extension ScheduleChromosome {

    // MARK: - CP-SAT Seeding

    /// Produce a single feasible chromosome by delegating the placement
    /// decision to `CPSATRepairer` (the same CDCL-lite solver the LNS
    /// operator already uses for large destroy windows). Returns nil if
    /// the solver times out without a complete assignment, or if the
    /// domain enumeration produces an empty set for any non-droppable
    /// gene — the caller falls back to greedy/random seeding in that
    /// case, matching the "CP is an accelerator, not a replacement"
    /// role documented on `OptimizerContext.cpSATRepairer`.
    ///
    /// Compared to `greedy(context:)`:
    ///   * CP considers all events jointly instead of one-at-a-time,
    ///     so a conflict between a priority-first greedy placement and
    ///     a later event's deadline gets backtracked cleanly instead
    ///     of forcing a drop.
    ///   * Precedence (`dependsOn`) is enforced at the search level
    ///     rather than as a post-hoc repair, so the first returned
    ///     assignment already honours the dependency DAG.
    ///   * Cost: O(|events|² · K) in the worst case (K = domain size).
    ///     For the 4-to-20-event plan-week workload this is sub-100ms
    ///     on current hardware; larger instances fall back through
    ///     the solver's built-in timeout.
    ///
    /// The returned chromosome is *not* fed through `repair()`; the CP
    /// assignment is feasible by construction (no overlap with fixed
    /// blocks, no overlap between movable events, all on working days
    /// in working hours). `createInitialPopulation`'s post-seed
    /// repair pass runs it through the rest of the normalisation
    /// machinery anyway, which is harmless on an already-feasible
    /// schedule.
    static func cpSeeded(
        context: OptimizerContext,
        warmStart: [ScheduleGene]? = nil
    ) -> ScheduleChromosome? {
        guard let repairer = context.cpSATRepairer else { return nil }
        guard !context.movableEvents.isEmpty else { return nil }

        let prefs = context.preferences
        let workingDays = prefs.workingDays
        let slotRegistry = context.ensureSlotRegistry()
        let slotSeconds: TimeInterval = slotRegistry.stride

        // Cap the per-event domain so the solver stays within budget on
        // dense weeks. On a 15-min grid 120 candidates ≈ 30h of
        // runway per event; on a 5-min grid we bump the cap to 360
        // so each event still sees the same time-domain coverage
        // (~30h). Keeps solve time comparable regardless of grid
        // granularity.
        let maxDomain = max(120, slotRegistry.stridesForMinutes(30 * 60))

        // Domain enumeration now reads from the precomputed
        // `SlotDomain` cache. The cache already excludes slots that
        // would:
        //   • start before `earliestStart` or leave no room before
        //     `deadline`;
        //   • end past the working-hours window of their day;
        //   • overlap any fixed event across the event's full
        //     duration.
        // Mutation / repair call paths consult the same cache, so
        // the CP-SAT seeder and the rest of the GA explore an
        // identical feasible domain — no drift between "what the
        // seeder thinks is legal" and "what a mutation can reach".
        _ = slotSeconds   // retained for backward-compat; no longer
                          // needed now that SlotDomain supplies the
                          // grid-aligned candidates.
        _ = workingDays   // idem — working-day filtering lives inside
                          // the registry build.
        func enumerateDomain(for event: OptimizableEvent) -> [Date] {
            let domain = context.ensureSlotDomain(for: event.id)
            guard !domain.isEmpty else { return [] }
            var candidates: [Date] = []
            candidates.reserveCapacity(min(domain.count, maxDomain))
            for idx in domain.indices {
                guard let date = slotRegistry.resolvedDate(at: idx) else { continue }
                candidates.append(date)
                if candidates.count >= maxDomain { break }
            }
            return candidates
        }

        // Map eventId → position in movableEvents so precedence and
        // assignment lookups can route through integer geneIndex the
        // CP solver expects.
        let indexByEventId: [String: Int] = Dictionary(
            uniqueKeysWithValues: context.movableEvents.enumerated().map { ($1.id, $0) }
        )

        // Build variables. Droppable events with an empty domain are
        // excluded from the solve (we keep them in the chromosome
        // post-hoc with `isIncluded = false`). Non-droppable events
        // with an empty domain mean the problem is infeasible at the
        // input level — bail to greedy/random fallback.
        var variables: [CPVariable] = []
        var excludedGeneIndices = Set<Int>()
        for (idx, event) in context.movableEvents.enumerated() {
            let domain = enumerateDomain(for: event)
            if domain.isEmpty {
                if event.isDroppable {
                    excludedGeneIndices.insert(idx)
                    continue
                } else {
                    return nil
                }
            }
            variables.append(CPVariable(geneIndex: idx, domain: domain, duration: event.duration))
        }
        guard !variables.isEmpty else { return nil }

        // Precedence: (i, j) means gene i ends before gene j starts.
        // Only include pairs where both sides made it into the variable
        // set (skipping excluded droppables).
        var precedence: [(Int, Int)] = []
        for event in context.movableEvents {
            guard let fromIdx = indexByEventId[event.id],
                  !excludedGeneIndices.contains(fromIdx) else { continue }
            for depId in event.dependsOn {
                guard let toIdx = indexByEventId[depId],
                      !excludedGeneIndices.contains(toIdx) else { continue }
                // event depends on depId → depId must end before event starts → (toIdx, fromIdx).
                precedence.append((toIdx, fromIdx))
            }
        }

        let fixedBlocks: [(start: Date, end: Date)] = context.fixedEvents.map {
            ($0.startDate, $0.endDate)
        }

        // True lexicographic hierarchy — no weight-gap tricks. Each
        // tier is solved as its own pass; the previous tier's
        // optimum becomes a hard constraint for everything below.
        // On a pathological workload where scalar-weighted lex could
        // be overwhelmed by tier-4 accumulation, the hierarchy
        // provably cannot be — an earlier tier's score is checked
        // and its branches pruned when they regress.
        //
        // Tier order matches the GA's three-tier `LexFitness` plus
        // a priority-earliness tiebreaker:
        //   1. inclusion (count of placed events)
        //   2. -deadline overrun (minutes, more negative = worse)
        //   3. -backlog inversions (count, more negative = worse)
        //   4. priority × earliness (sum over placed events)
        let backlogById = context.backlogIndexMap()
        let priorityByIndex: [Int: Double] = Dictionary(
            uniqueKeysWithValues: context.movableEvents.enumerated().map { ($0, $1.priority) }
        )
        let deadlineByIndex: [Int: Date] = Dictionary(
            uniqueKeysWithValues: context.movableEvents.enumerated().compactMap { idx, ev in
                ev.deadline.map { (idx, $0) }
            }
        )
        let durationByIndex: [Int: TimeInterval] = Dictionary(
            uniqueKeysWithValues: context.movableEvents.enumerated().map { ($0, $1.duration) }
        )
        let backlogRankByIndex: [Int: Int] = Dictionary(
            uniqueKeysWithValues: context.movableEvents.enumerated().compactMap { idx, ev in
                backlogById[ev.id].map { (idx, $0) }
            }
        )
        let horizonStartRef = context.planningHorizon.start.timeIntervalSinceReferenceDate
        let horizonSpan = max(1, context.planningHorizon.end.timeIntervalSinceReferenceDate - horizonStartRef)
        let tiers: [CPSATRepairer.LexTier] = [
            CPSATRepairer.LexTier(
                name: "inclusion",
                extract: { assignment in Double(assignment.count) }
            ),
            CPSATRepairer.LexTier(
                name: "deadline",
                extract: { assignment in
                    var overrun = 0.0
                    for (idx, start) in assignment {
                        guard let deadline = deadlineByIndex[idx],
                              let duration = durationByIndex[idx] else { continue }
                        let end = start.addingTimeInterval(duration)
                        if end > deadline {
                            overrun += end.timeIntervalSince(deadline) / 60.0
                        }
                    }
                    return -overrun
                }
            ),
            CPSATRepairer.LexTier(
                name: "backlog",
                extract: { assignment in
                    let ranked: [(rank: Int, start: Date)] = assignment.compactMap { idx, start in
                        backlogRankByIndex[idx].map { (rank: $0, start: start) }
                    }
                    guard ranked.count >= 2 else { return 0 }
                    var inversions = 0
                    for i in 0..<ranked.count {
                        for j in (i + 1)..<ranked.count {
                            let a = ranked[i]
                            let b = ranked[j]
                            if a.rank < b.rank && a.start > b.start {
                                inversions += 1
                            } else if b.rank < a.rank && b.start > a.start {
                                inversions += 1
                            }
                        }
                    }
                    return -Double(inversions)
                }
            ),
            CPSATRepairer.LexTier(
                name: "earliness",
                extract: { assignment in
                    var total = 0.0
                    for (idx, date) in assignment {
                        let priority = priorityByIndex[idx] ?? 0.5
                        let position = (date.timeIntervalSinceReferenceDate - horizonStartRef) / horizonSpan
                        total += priority * (1.0 - position)
                    }
                    return total
                }
            ),
        ]

        // Project the caller's warm-start genes into the solver's
        // `[geneIndex: Date]` space. Only included genes whose
        // eventId resolves to an active variable and whose start
        // time lives in that variable's precomputed domain make it
        // into the hint — anything else would fail the repairer's
        // feasibility gate anyway, and a partial/out-of-domain hint
        // there is silently dropped (never a correctness issue,
        // just a missed warm-start).
        let hint: [Int: Date]? = warmStart.flatMap { genes in
            var out: [Int: Date] = [:]
            let domains: [Int: Set<Date>] = Dictionary(
                uniqueKeysWithValues: variables.map { v in
                    (v.geneIndex, Set(v.domain))
                }
            )
            for gene in genes where gene.isIncluded {
                guard
                    let idx = indexByEventId[gene.eventId],
                    !excludedGeneIndices.contains(idx),
                    let domain = domains[idx],
                    domain.contains(gene.startTime)
                else { continue }
                out[idx] = gene.startTime
            }
            return out.count == variables.count ? out : nil
        }

        let result = repairer.solveLexHierarchy(
            variables: variables,
            precedence: precedence,
            fixedBlocks: fixedBlocks,
            tiers: tiers,
            hint: hint
        )

        // Require every variable to have an assignment — a partial
        // result from a timeout is worse than a greedy seed here
        // because the GA would have to repair unplaced genes anyway.
        guard !result.wasTimedOut || result.assignments.count == variables.count else {
            return nil
        }
        guard result.assignments.count == variables.count else { return nil }

        var genes: [ScheduleGene] = []
        genes.reserveCapacity(context.movableEvents.count)
        for (idx, event) in context.movableEvents.enumerated() {
            let rawStart: Date
            let included: Bool
            if excludedGeneIndices.contains(idx) {
                // Droppable with empty domain → keep at a nominal slot
                // and flag excluded. Nominal slot is the earliest
                // horizon edge so comparisons stay well-behaved.
                rawStart = context.planningHorizon.start
                included = false
            } else if let assigned = result.assignments[idx] {
                rawStart = assigned
                included = true
            } else {
                // Shouldn't happen given the count-match guard above,
                // but fall through defensively rather than crashing.
                return nil
            }
            // Snap to registry grid so `startTime` matches the slot
            // the index resolves to — see `random(context:)` rationale.
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
        }
        return ScheduleChromosome(genes: genes, needsEvaluation: true)
    }

    /// Find the first gap in the schedule that fits the event duration.
    ///
    /// Internal (was `private`) so the `Chromosome+Initialization.swift`
    /// sibling file can call it from `random(...)` / `greedyWithOrder(...)`.
    /// `findLastFreeSlot` / `enumerateFeasibleSlots` / `OccupiedInterval`
    /// stay private to this file — only `findFirstFreeSlot` crosses the
    /// boundary because the initialisation paths happen to need it.
    static func findFirstFreeSlot(
        duration: TimeInterval,
        preferredHours: ClosedRange<Int>?,
        occupied: [(start: Date, end: Date)],
        horizon: DateInterval,
        workingHours: ClosedRange<Int>,
        calendar: Calendar,
        earliestStart: Date?,
        deadline: Date?,
        dependsOn: [String],
        placedGenes: [ScheduleGene],
        genesByEvent: [String: Int],
        workingDays: Set<Int> = [],
        eventId: String? = nil,
        context: OptimizerContext? = nil
    ) -> Date? {
        let horizonStartDay = calendar.startOfDay(for: horizon.start)
        let horizonLastDay = calendar.startOfDay(for: horizon.end.addingTimeInterval(-1))
        let daysInHorizon = max(1, (calendar.dateComponents([.day], from: horizonStartDay, to: horizonLastDay).day ?? 0) + 1)

        // Earliest possible start considering dependencies
        var floor = earliestStart ?? horizon.start
        if floor < horizon.start { floor = horizon.start }
        for depId in dependsOn {
            if let depGene = placedGenes.first(where: { $0.eventId == depId && $0.isIncluded }) {
                floor = max(floor, depGene.endTime)
            }
        }

        // Fast path: consult the precomputed per-event slot domain
        // when the caller supplied both `eventId` and `context`.
        // The domain already encodes `earliestStart`, event-level
        // `deadline`, working-hours fit and fixed-event non-overlap,
        // so the only runtime filters are:
        //   • the chromosome-specific `occupied` intervals;
        //   • the dependency-derived `floor` above;
        //   • a caller-supplied `deadline` that may be *tighter*
        //     than the event's static deadline (LNS reverse-deps).
        // Iterating the domain (typically ≤200 entries) is strictly
        // cheaper than the day-by-day stride walk below (~28×h
        // working hours × slots-per-hour).
        if let eventId, let context {
            let registry = context.ensureSlotRegistry()
            let domain = context.ensureSlotDomain(for: eventId)
            if !domain.isEmpty {
                let feasibleStart = domain.indices(after: floor, registry: registry)
                for idx in feasibleStart {
                    guard let candidate = registry.resolvedDate(at: idx) else { continue }
                    let candidateEnd = candidate.addingTimeInterval(duration)
                    // Dynamic deadline (tighter than static) — break
                    // on overshoot since domain is chronologically
                    // sorted, so every later entry overshoots too.
                    if let deadline, candidateEnd > deadline { break }
                    let hasOverlap = occupied.contains { occ in
                        candidate < occ.end && candidateEnd > occ.start
                    }
                    if !hasOverlap {
                        return candidate
                    }
                }
                // Domain was non-empty but every entry conflicts
                // with current `occupied` (or dynamic deadline) —
                // no feasible slot.
                return nil
            }
        }

        // Try each day, preferring preferred hours
        for dayOffset in 0..<daysInHorizon {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: horizonStartDay) else { continue }
            // Skip non-working days when the caller asked us to — matches
            // the `WorkingHoursConstraint` day-of-week branch so greedy
            // seeding and LNS re-insertion don't probe days the hard
            // constraint will immediately reject. Empty set = no filter
            // (legacy caller that doesn't care about day-of-week).
            if !workingDays.isEmpty {
                let weekday = calendar.component(.weekday, from: day)
                if !workingDays.contains(weekday) { continue }
            }
            let hourRange = preferredHours ?? workingHours
            guard let dayWorkStart = calendar.date(bySettingHour: hourRange.lowerBound, minute: 0, second: 0, of: day),
                  let dayWorkEnd = calendar.date(bySettingHour: min(hourRange.upperBound, workingHours.upperBound), minute: 0, second: 0, of: day) else { continue }

            // Candidate starts at 15-minute intervals
            var candidate = max(dayWorkStart, floor)
            let latestStart = dayWorkEnd.addingTimeInterval(-duration)
            if let deadline, latestStart > deadline.addingTimeInterval(-duration) {
                continue // whole day is past deadline
            }

            while candidate <= latestStart {
                let candidateEnd = candidate.addingTimeInterval(duration)

                // Check deadline
                if let deadline, candidateEnd > deadline { break }

                // Check overlap with occupied intervals
                let hasOverlap = occupied.contains { occ in
                    candidate < occ.end && candidateEnd > occ.start
                }

                if !hasOverlap {
                    return candidate
                }

                // Jump past the overlapping event (minimum 1-minute advance to prevent infinite loop)
                if let blocker = occupied.first(where: { candidate < $0.end && candidateEnd > $0.start }) {
                    let nextCandidate = blocker.end
                    candidate = nextCandidate > candidate ? nextCandidate : candidate.addingTimeInterval(900)
                } else {
                    candidate = candidate.addingTimeInterval(900) // 15 min
                }
            }
        }

        return nil
    }

    /// Symmetric counterpart to `findFirstFreeSlot`: walks the horizon in
    /// reverse and returns the *latest* feasible start time that still
    /// respects working hours, the deadline, the earliestStart/dependency
    /// floor, and every interval in `occupied`. Used by the LNS regret
    /// insertion to measure each gene's placement window — the smaller
    /// the gap between earliest and latest, the tighter the gene and the
    /// higher its regret if deferred.
    ///
    /// Returns `nil` when no 15-minute-aligned slot fits anywhere. Same
    /// semantics as `findFirstFreeSlot`: dependency satisfaction is
    /// checked against `placedGenes`, the caller supplies `occupied`
    /// minus any genes that are themselves about to move.
    ///
    /// Internal (was `private`) so `Chromosome+CPSATRepair.swift` can
    /// call it when relocating destroyed genes during LNS repair.
    static func findLastFreeSlot(
        duration: TimeInterval,
        preferredHours: ClosedRange<Int>?,
        occupied: [(start: Date, end: Date)],
        horizon: DateInterval,
        workingHours: ClosedRange<Int>,
        calendar: Calendar,
        earliestStart: Date?,
        deadline: Date?,
        dependsOn: [String],
        placedGenes: [ScheduleGene],
        genesByEvent: [String: Int],
        workingDays: Set<Int> = []
    ) -> Date? {
        let horizonStartDay = calendar.startOfDay(for: horizon.start)
        let horizonLastDay = calendar.startOfDay(for: horizon.end.addingTimeInterval(-1))
        let daysInHorizon = max(1, (calendar.dateComponents([.day], from: horizonStartDay, to: horizonLastDay).day ?? 0) + 1)

        var floor = earliestStart ?? horizon.start
        if floor < horizon.start { floor = horizon.start }
        for depId in dependsOn {
            if let depGene = placedGenes.first(where: { $0.eventId == depId && $0.isIncluded }) {
                floor = max(floor, depGene.endTime)
            }
        }

        let ceiling = deadline.map { min($0, horizon.end) } ?? horizon.end

        // Walk days in reverse, searching for the latest feasible start.
        for dayOffset in stride(from: daysInHorizon - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: horizonStartDay) else { continue }
            if !workingDays.isEmpty {
                let weekday = calendar.component(.weekday, from: day)
                if !workingDays.contains(weekday) { continue }
            }
            let hourRange = preferredHours ?? workingHours
            guard let dayWorkStart = calendar.date(bySettingHour: hourRange.lowerBound, minute: 0, second: 0, of: day),
                  let dayWorkEnd = calendar.date(bySettingHour: min(hourRange.upperBound, workingHours.upperBound), minute: 0, second: 0, of: day) else { continue }

            let dayFloor = max(dayWorkStart, floor)
            let dayEnd = min(dayWorkEnd, ceiling)
            let latestStartOnDay = dayEnd.addingTimeInterval(-duration)
            if latestStartOnDay < dayFloor { continue }

            // Snap latestStartOnDay down to a 15-min grid so we match
            // findFirstFreeSlot's stepping and the two functions agree on
            // boundary cases.
            let secs = latestStartOnDay.timeIntervalSinceReferenceDate
            let snapped = Date(timeIntervalSinceReferenceDate: (secs / 900).rounded(.down) * 900)
            var candidate = min(latestStartOnDay, snapped)

            while candidate >= dayFloor {
                let candidateEnd = candidate.addingTimeInterval(duration)
                if candidateEnd <= ceiling {
                    let hasOverlap = occupied.contains { occ in
                        candidate < occ.end && candidateEnd > occ.start
                    }
                    if !hasOverlap {
                        return candidate
                    }
                }

                // Step back before the blocker so we skip its span in
                // one jump; otherwise retreat by 15 minutes.
                if let blocker = occupied.first(where: { candidate < $0.end && candidateEnd > $0.start }) {
                    let prevEnd = blocker.start.addingTimeInterval(-duration)
                    let s = prevEnd.timeIntervalSinceReferenceDate
                    candidate = Date(timeIntervalSinceReferenceDate: (s / 900).rounded(.down) * 900)
                } else {
                    candidate = candidate.addingTimeInterval(-900)
                }
            }
        }

        return nil
    }

    /// Occupied time interval carrying the gene/event metadata that the
    /// LNS cost proxy needs to score richer objectives (ContextSwitch,
    /// BreakPlacement, WeekBalance). Only `enumerateFeasibleSlots` and
    /// `cpRepair` use this shape — other repair paths keep the simpler
    /// `(start: Date, end: Date)` tuple to avoid a cross-cutting refactor.
    ///
    /// Visibility relaxed from `fileprivate` to internal so
    /// `Chromosome+CPSATRepair.swift` (the sibling file that owns the
    /// LNS repair path) can reference it in signatures and bodies.
    struct OccupiedInterval {
        let start: Date
        let end: Date
        /// The event's context tag (e.g. project name). `nil` when the
        /// source is a fixed calendar event with no tag.
        let context: String?
        /// `true` when the occupying item is a focus block — used by the
        /// focus-block continuity signal to skip focus-within-focus
        /// rewards.
        let isFocusBlock: Bool
    }

    /// Enumerate the top-K feasible start slots for one gene against a
    /// given occupied set, sorted by a cost proxy that approximates the
    /// GA's real fitness. Used by the CP branch-and-bound repair as the
    /// per-gene domain.
    ///
    /// Cost proxy weights eleven per-slot signals, each mapping to one or
    /// more of the 13 GA objectives. The full signal list, with the GA
    /// objective it proxies:
    ///
    ///   1. Preferred-hour fit        → TaskPlacement, PomodoroFit
    ///   2. Energy alignment          → EnergyBalance
    ///   3. Buffer gap                → Buffer
    ///   4. Deadline slack            → Deadline
    ///   5. Focus-block continuity    → FocusBlock
    ///   6. Meeting clustering        → MeetingClustering
    ///   7. Earliness                 → tie-breaker
    ///   8. Context switch            → ContextSwitch       (requires rich occupied)
    ///   9. Pomodoro alignment        → PomodoroFit
    ///  10. Break placement           → BreakPlacement      (requires rich occupied)
    ///  11. Week balance              → WeekBalance         (requires rich occupied)
    ///
    /// Signals 8, 10, 11 lean on `OccupiedInterval.context` and same-day
    /// density; the others work from time-only information. All weights
    /// scale with matching user `OptimizerPreferences` so the proxy
    /// adapts to individual emphasis. The cost is a search heuristic,
    /// not a fitness substitute — the real evaluator recomputes after
    /// mutation. The proxy's job is to keep BnB pruning on the right
    /// side of the fitness landscape while committing to placements.
    ///
    /// Internal (was `private`) so `Chromosome+CPSATRepair.swift` can
    /// build per-event domains during the LNS repair pass.
    static func enumerateFeasibleSlots(
        duration: TimeInterval,
        topK: Int,
        preferredHours: ClosedRange<Int>?,
        occupied: [OccupiedInterval],
        horizon: DateInterval,
        workingHours: ClosedRange<Int>,
        calendar: Calendar,
        earliestStart: Date?,
        deadline: Date?,
        dependsOn: [String],
        placedGenes: [ScheduleGene],
        energyCost: Double,
        isFocusBlock: Bool,
        geneContext: String?,
        preferences: OptimizerPreferences
    ) -> [(slot: Date, cost: Double)] {
        let horizonStartDay = calendar.startOfDay(for: horizon.start)
        let horizonLastDay = calendar.startOfDay(for: horizon.end.addingTimeInterval(-1))
        let daysInHorizon = max(1, (calendar.dateComponents([.day], from: horizonStartDay, to: horizonLastDay).day ?? 0) + 1)

        var floor = earliestStart ?? horizon.start
        if floor < horizon.start { floor = horizon.start }
        for depId in dependsOn {
            if let depGene = placedGenes.first(where: { $0.eventId == depId && $0.isIncluded }) {
                floor = max(floor, depGene.endTime)
            }
        }
        let ceiling = deadline.map { min($0, horizon.end) } ?? horizon.end
        let horizonSecs = max(1, horizon.end.timeIntervalSince(horizon.start))

        let requiredBufferSecs = TimeInterval(
            (energyCost > 0.7
                ? preferences.heavyMeetingBufferMinutes
                : preferences.defaultBufferMinutes
            ) * 60
        )
        let idealFocusSecs = TimeInterval(preferences.idealFocusBlockMinutes * 60)
        let minBreakSecs = TimeInterval(preferences.minBreakMinutes * 60)
        let clusterWindow = preferences.preferredClusterWindowStart..<preferences.preferredClusterWindowEnd
        let maxPerDay = max(1, preferences.maxMeetingsPerDay)

        var candidates: [(slot: Date, cost: Double)] = []
        candidates.reserveCapacity(64)

        for dayOffset in 0..<daysInHorizon {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: horizonStartDay) else { continue }
            let hourRange = preferredHours ?? workingHours
            guard let dayWorkStart = calendar.date(bySettingHour: hourRange.lowerBound, minute: 0, second: 0, of: day),
                  let dayWorkEnd = calendar.date(bySettingHour: min(hourRange.upperBound, workingHours.upperBound), minute: 0, second: 0, of: day) else { continue }

            let dayFloor = max(dayWorkStart, floor)
            let latestStart = dayWorkEnd.addingTimeInterval(-duration)
            if latestStart < dayFloor { continue }

            let floorSecs = dayFloor.timeIntervalSinceReferenceDate
            let snappedFloor = Date(timeIntervalSinceReferenceDate: (floorSecs / 900).rounded(.up) * 900)
            var candidate = max(dayFloor, snappedFloor)

            // Pre-compute same-day occupied count once per day — used by
            // the WeekBalance signal for every candidate on this day.
            let dayStart = calendar.startOfDay(for: day)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            let sameDayCount = occupied.reduce(0) {
                $0 + (($1.start >= dayStart && $1.start < nextDay) ? 1 : 0)
            }

            while candidate <= latestStart {
                let candidateEnd = candidate.addingTimeInterval(duration)
                if candidateEnd > ceiling { break }

                let blocker = occupied.first { occ in
                    candidate < occ.end && candidateEnd > occ.start
                }
                if let blocker {
                    candidate = max(blocker.end, candidate.addingTimeInterval(900))
                    let s = candidate.timeIntervalSinceReferenceDate
                    candidate = Date(timeIntervalSinceReferenceDate: (s / 900).rounded(.up) * 900)
                    continue
                }

                let hour = calendar.component(.hour, from: candidate)
                let minute = calendar.component(.minute, from: candidate)

                // 1. Preferred-hour fit.
                let prefPenalty: Double
                if let p = preferredHours {
                    if p.contains(hour) {
                        prefPenalty = 0.0
                    } else {
                        let distance = min(abs(hour - p.lowerBound), abs(hour - p.upperBound))
                        prefPenalty = min(1.0, Double(distance) * 0.2)
                    }
                } else {
                    prefPenalty = 0.0
                }

                // 2. Energy alignment.
                let energyLevel: Double
                if let curve = preferences.personalEnergyCurve, curve.count == 24, hour >= 0, hour < 24 {
                    energyLevel = max(0, min(1, curve[hour]))
                } else {
                    let d = preferences.peakEnergyDistance(from: hour)
                    energyLevel = exp(-Double(d) * Double(d) * 0.02)
                }
                let energyMisalign = energyCost * (1.0 - energyLevel)

                // 3. Buffer gap (defaultBufferMinutes).
                var bufferPenalty = 0.0
                var gapAfter: TimeInterval = .infinity
                var nextInterval: OccupiedInterval? = nil
                for occ in occupied where occ.start >= candidateEnd {
                    nextInterval = occ
                    gapAfter = occ.start.timeIntervalSince(candidateEnd)
                    break
                }
                if requiredBufferSecs > 0 && gapAfter < requiredBufferSecs {
                    bufferPenalty = 1.0 - gapAfter / requiredBufferSecs
                }

                // 4. Deadline slack.
                var deadlineBonus = 0.0
                if let dl = deadline {
                    let slack = max(0, dl.timeIntervalSince(candidateEnd))
                    deadlineBonus = 1.0 - exp(-slack / (24.0 * 3600.0))
                }

                // 5. Focus-block continuity.
                var focusBonus = 0.0
                if isFocusBlock, idealFocusSecs > 0 {
                    let gapBefore: TimeInterval
                    if let prev = occupied.last(where: { $0.end <= candidate }) {
                        gapBefore = candidate.timeIntervalSince(prev.end)
                    } else {
                        gapBefore = .infinity
                    }
                    let combinedGap = duration + min(gapBefore, 3600) + min(gapAfter, 3600)
                    focusBonus = combinedGap >= idealFocusSecs ? 1.0 : combinedGap / idealFocusSecs
                }

                // 6. Meeting clustering.
                let clusterBonus: Double = (!isFocusBlock && clusterWindow.contains(hour)) ? 1.0 : 0.0

                // 7. Earliness tie-breaker.
                let earliness = min(1.0, max(0.0, candidate.timeIntervalSince(horizon.start) / horizonSecs))

                // 8. Context switch. Penalty when either neighbour has a
                // different context tag from the current gene. nil
                // contexts don't participate (unknown context should not
                // force a false-positive penalty).
                var contextSwitch = 0.0
                if let myCtx = geneContext {
                    if let next = nextInterval, let nCtx = next.context, nCtx != myCtx {
                        contextSwitch += 0.5
                    }
                    if let prev = occupied.last(where: { $0.end <= candidate }),
                       let pCtx = prev.context, pCtx != myCtx {
                        contextSwitch += 0.5
                    }
                }

                // 9. Pomodoro alignment. Bonus for :00 / :30 starts over
                // :15 / :45. Cheap O(1) proxy for PomodoroFit.
                let pomodoroBonus: Double = (minute == 0 || minute == 30) ? 1.0 : 0.0

                // 10. Break placement. Uses `minBreakMinutes` (cognitive
                // break) which is distinct from `defaultBufferMinutes`
                // (calendar safety). If gap to next item is below the
                // minimum break threshold, penalize.
                var breakPenalty = 0.0
                if minBreakSecs > 0 && gapAfter < minBreakSecs {
                    breakPenalty = 1.0 - gapAfter / minBreakSecs
                }

                // 11. Week balance. Avoid overstuffing a single day.
                let weekPenalty = min(1.0, Double(sameDayCount) / Double(maxPerDay))

                let cost = prefPenalty * 1.0
                         + energyMisalign * preferences.energyCurveWeight
                         + bufferPenalty * preferences.bufferWeight
                         + breakPenalty * preferences.breakWeight
                         + contextSwitch * preferences.contextSwitchWeight
                         + weekPenalty * preferences.weekBalanceWeight * 0.2
                         - deadlineBonus * preferences.deadlineWeight * 0.3
                         - focusBonus * preferences.focusBlockWeight * 0.3
                         - clusterBonus * preferences.meetingClusteringWeight * 0.2
                         - pomodoroBonus * preferences.pomodoroFitWeight * 0.1
                         + earliness * 0.1
                candidates.append((candidate, cost))
                candidate = candidate.addingTimeInterval(900)
            }
        }

        candidates.sort { $0.cost < $1.cost }
        if candidates.count > topK {
            candidates.removeLast(candidates.count - topK)
        }
        return candidates
    }

}
