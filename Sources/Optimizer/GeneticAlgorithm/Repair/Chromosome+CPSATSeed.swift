import Foundation
import BuboDomain

// MARK: - ScheduleChromosome CP-SAT seeding
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
// The slot-search helpers (`findFirstFreeSlot`, `findLastFreeSlot`,
// `enumerateFeasibleSlots`, `OccupiedInterval`) used to live here too;
// extracted to `Chromosome+SlotSearch.swift` on 2026-05-13 so each
// file stays under ~500 lines.

public extension ScheduleChromosome {

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

}
