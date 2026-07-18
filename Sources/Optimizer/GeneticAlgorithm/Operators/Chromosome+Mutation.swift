import Foundation

// MARK: - ScheduleChromosome mutation + LNS dispatch
//
// `mutate(rate:context:)` — the entry point the GA calls every
// generation. Internally:
//   1. Self-adaptive mutation rate read from the genome (if enabled).
//   2. Per-gene roll: bandit picks an operator (snap-to-grid, shift,
//      move-day, swap, guided-move, etc.) keyed on `MutationBandit`.
//   3. Bookkeeping for `lastMutationOperator` so the GA loop can
//      attribute the post-evaluation fitness delta back to the
//      operator that produced it (LinUCB closed loop).
//
// `applyLNS(rate:context:)` — the Large Neighborhood Search operator
// the bandit reaches for on harder workloads. Destroys a window of
// genes (multiple strategies: day-block, related-events, worst-fit,
// random) and re-inserts via CP-SAT repair, with `regretRepair` as
// fallback when the CP-SAT branch-and-bound runs out of time budget.
//
// Extracted from `Chromosome.swift`; visibility changes:
//   • `applyCPSATRepair`, `destroy`, `cpRepair`, `regretRepair` in
//     `Chromosome.swift` dropped `private` so `applyLNS` here can
//     drive them.
//   • `applyLNS` stays `private` to this file — only `mutate(...)` in
//     this same file calls it.

public extension ScheduleChromosome {

    // MARK: - Mutation

    mutating func mutate(rate: Double, context: OptimizerContext) {
        needsEvaluation = true
        // Gene placement is changing; any previously-recorded fitness
        // is stale, so the flag must revert until a fresh evaluation
        // produces a new score. Without this, a real-evaluated parent
        // whose genes get mutated could keep `isFitnessReal = true`
        // while its fitness now refers to the pre-mutation layout —
        // silently poisoning downstream boundary checks.
        isFitnessReal = false
        // Feature cache is a function of gene placement; mutation may
        // change placement, invalidate eagerly. Surrogate screen will
        // recompute on next access.
        cachedFeatures = nil
        var changed = IndexSet()
        let cal = context.calendar
        let horizonStart = context.planningHorizon.start
        // Slot registry: the discrete search space this mutation
        // operates on. Every case below prefers slot-index arithmetic
        // (clean, bounded, discrete) and falls back to the legacy
        // `Date` path only when the registry is empty or the gene
        // carries no slot binding yet — exactly the conditions under
        // which the continuous path was the only option before the
        // slot-decoder refactor.
        let slotRegistry = context.ensureSlotRegistry()

        // Self-adaptive rate override. When the chromosome carries its own
        // rate (inherited from parents or bootstrapped by the GA), perturb
        // the rate first and then use the perturbed value as the *effective*
        // mutation rate for this call. The small Gaussian-ish step keeps
        // neighbourhood size under control — ±0.02 per step is big enough
        // to drift but small enough that a good rate isn't lost in one draw.
        let effectiveRate: Double
        if selfAdaptiveMutationRate > 0 {
            let delta = context.rng.double(in: -0.02...0.02)
            selfAdaptiveMutationRate = min(0.8, max(0.01, selfAdaptiveMutationRate + delta))
            effectiveRate = selfAdaptiveMutationRate
        } else {
            effectiveRate = rate
        }

        // Choose one operator for this entire call and use it for every
        // gene that gets selected. The feedback loop works at call
        // granularity (pre vs. post fitness), so per-gene operator
        // variation would make the reward signal harder to attribute.
        let bandedOperator = context.mutationBandit.select(rng: context.rng)
        lastMutationOperator = bandedOperator

        // LNS is a whole-subset operator: it picks a coherent chunk of genes
        // (a day, or the top-K by priority) and re-inserts them greedily in
        // one pass, instead of perturbing genes one-at-a-time. Taking the
        // per-gene loop below would dilute the destroy/repair semantics, so
        // dispatch it here and return.
        if bandedOperator == .lnsDay {
            // Union, not overwrite: after a constraint-rejected eval the
            // indices deliberately survive (see `evaluateAndAssign`), and
            // they must keep accumulating until a successful eval clears
            // them — otherwise the per-day delta cache marks previously
            // moved days clean.
            if let lnsChanged = applyLNS(rate: effectiveRate, context: context) {
                mutatedGeneIndices = (mutatedGeneIndices ?? IndexSet()).union(lnsChanged)
            }
            return
        }

        for i in genes.indices {
            guard context.rng.bool(probability: effectiveRate) else { continue }

            changed.insert(i)

            // Droppable genes: small chance to flip inclusion instead of moving
            if genes[i].isDroppable && context.rng.bool(probability: 0.15) {
                genes[i].isIncluded.toggle()
                continue
            }

            // Skip placement mutation for excluded genes
            guard genes[i].isIncluded else { continue }

            let event = context.movableEvents.first { $0.id == genes[i].eventId }
            let earliest = event?.earliestStart
            let floor = [horizonStart, earliest].compactMap { $0 }.max() ?? horizonStart
            let strategy = bandedOperator.rawValue

            switch strategy {
            case 0:
                // Small time shift — ±2 slots (±30 min on the 15-min
                // grid). Every registry slot is by construction on a
                // working day inside working hours and not inside a
                // fixed block, so the result is placement-feasible
                // without any post-hoc sanitation.
                //
                // An empty registry (degenerate horizon / pathological
                // config) simply skips this mutation — better than
                // reintroducing a continuous-Date jitter that could
                // land off-grid or off-day.
                guard let currentSlot = genes[i].slotIndex ?? slotRegistry.nearestIndex(to: genes[i].startTime) else { break }
                // Δ in *slot units*, auto-scaling with the registry's
                // stride. `stridesForMinutes(30)` returns 2 on a
                // 15-min grid (±30 min), 6 on a 5-min grid (±30 min) —
                // keeps the shift operator's time-domain neighbourhood
                // constant even when the grid gets finer.
                let window = slotRegistry.stridesForMinutes(30)
                let delta = context.rng.int(in: -window...window)
                let newSlot = slotRegistry.clamped(currentSlot + delta)
                guard let newDate = slotRegistry.resolvedDate(at: newSlot),
                      newDate >= floor else { break }
                genes[i] = genes[i].withSlot(index: newSlot, date: newDate)
            case 1:
                // Move to a different day — slot-based. Sample uniformly
                // across every registry index that could host this gene
                // under the current floor/ceiling. Registry slots are
                // pre-filtered for working-days, working-hours, horizon
                // and fixed-event overlaps, so a random pick is feasible
                // by construction.
                //
                // Dependency floor folds into the lower bound so a draw
                // can't land before any `dependsOn` predecessor
                // finishes; the result otherwise respects
                // `earliestStart`, `deadline`, and duration fit on the
                // target day.
                var effectiveFloor = floor
                if let event, !event.dependsOn.isEmpty {
                    for depId in event.dependsOn {
                        if let depGene = genes.first(where: { $0.eventId == depId && $0.isIncluded }) {
                            effectiveFloor = max(effectiveFloor, depGene.endTime)
                        }
                    }
                }

                // Per-gene precomputed domain replaces the per-mutation
                // `allowedIndices` binary search + fixed-event overlap
                // scan. The domain already excludes slots that would
                // overlap a fixed event across the full duration, so a
                // random pick from the domain is placement-feasible by
                // construction. Dependency floor is the only dynamic
                // constraint — we binary-search the domain for the
                // first entry past the floor instead of rebuilding the
                // candidate set.
                guard !slotRegistry.isEmpty else { break }
                let domain = context.ensureSlotDomain(for: genes[i].eventId)
                let feasible = domain.indices(after: effectiveFloor, registry: slotRegistry)
                guard !feasible.isEmpty else { break }
                let pick = feasible[context.rng.int(in: feasible.startIndex..<feasible.endIndex)]
                guard let newDate = slotRegistry.resolvedDate(at: pick) else { break }
                genes[i] = genes[i].withSlot(index: pick, date: newDate)
            case 2:
                // Slot-based snap: align to the nearest registry slot.
                // The registry is a superset of every placement the
                // other operators produce, so "snap to registry" is
                // the slot-decoder equivalent of "snap to grid" —
                // folds any Date drift (from legacy `withStartTime`
                // callers, or crossover that inherited a slot from
                // an incompatible registry) back onto the canonical
                // discrete lattice. Serves as a cheap sanity operator
                // that never worsens feasibility.
                guard !slotRegistry.isEmpty,
                      let slot = slotRegistry.nearestIndex(to: genes[i].startTime),
                      let date = slotRegistry.resolvedDate(at: slot),
                      date >= floor else { break }
                genes[i] = genes[i].withSlot(index: slot, date: date)
            case 3:
                // Guided mutation: find nearest free gap that also
                // avoids overlapping other included genes. The Date
                // result is mapped back onto the registry index so
                // the gene retains its slot binding — this is the
                // only case that has to go via Date because the gap
                // scan considers per-evaluation occupied intervals,
                // which the registry doesn't track (the registry
                // only knows fixed events; movable events move
                // between generations).
                let occupied = collectOccupiedIntervals(excluding: i, context: context)
                if let freeStart = findNearestFreeSlot(
                    near: genes[i].startTime,
                    duration: genes[i].duration,
                    occupied: occupied,
                    workingHours: context.workingHours,
                    horizon: context.planningHorizon,
                    calendar: cal,
                    floor: floor,
                    workingDays: context.preferences.workingDays
                ) {
                    genes[i] = genes[i].withSlot(nearest: freeStart, registry: slotRegistry)
                }
            default:
                break
            }
        }
        // Union with any indices left over from a constraint-rejected
        // eval (see above) — a successful eval is the only thing that
        // clears the set.
        if !changed.isEmpty {
            mutatedGeneIndices = (mutatedGeneIndices ?? IndexSet()).union(changed)
        }
    }

    // MARK: - LNS (Large Neighborhood Search) Operator

    /// Destroy a coherent subset of the schedule and re-insert every
    /// destroyed gene via a budgeted CP-style branch-and-bound.
    ///
    /// **Destroy**: one of five strategies (`day`, `topPriority`, `random`,
    /// `relatedContext`, `worstFit`) picked by `LNSStrategyBandit` using
    /// ALNS-style roulette weights. Strategy weights update per-call from
    /// the same fitness delta that drives the operator-level LinUCB, so a
    /// destroy that repeatedly helps gets picked more often.
    ///
    /// **Adaptive K**: destroy size scales with both the effective mutation
    /// rate *and* the bandit's stagnation signal. When the GA is stuck
    /// (`stagnation ≈ 1`), K inflates by up to 2.5×, widening the search
    /// neighbourhood exactly when small local moves stop paying off.
    ///
    /// **Repair**: budgeted CP-style branch-and-bound over the slot
    /// domain of each destroyed gene, with forward checking (eager
    /// domain filtering after every placement) and dom/deg variable
    /// ordering (fail-first: smallest remaining domain, ties broken by
    /// degree then priority). Topological precedence is enforced by
    /// in-degree gating on the ready set. Cost-based pruning skips any
    /// branch whose partial accumulated cost already exceeds the best
    /// complete solution. Falls back to regret insertion when the node
    /// budget runs out without any complete solution; that fallback is
    /// itself topo-aware with reverse-dependency handling.
    ///
    /// **Reverse dependencies**: when a destroyed gene Y has a non-destroyed
    /// dependent X already placed at time T, Y's effective deadline becomes
    /// `min(Y.deadline, X.startTime)` — otherwise we could place Y after
    /// X and silently break the ordering.
    ///
    /// Complexity per call: O(D · K^D) worst-case, where D = destroyed
    /// count, K = branching factor per gene. A 2000-node expansion budget
    /// caps runtime at ~1 ms for D ≤ 15, K ≈ 6. Aggressive cost pruning
    /// means typical runs explore 50–200 nodes before converging.
    private mutating func applyLNS(rate: Double, context: OptimizerContext) -> IndexSet? {
        let includedIndices = genes.indices.filter { genes[$0].isIncluded }
        guard !includedIndices.isEmpty else { return nil }

        // Adaptive K: base size from rate, amplified by stagnation. The
        // bandit already exposes `stagnation` as part of `BanditContext`;
        // reading it here gives the operator the same regime awareness
        // arm selection uses, without plumbing it through every call.
        let stagnation = context.mutationBandit.lastContext.stagnation
        let baseK = Int((Double(includedIndices.count) * max(0.15, rate * 2.0)).rounded())
        let adaptiveK = Int((Double(baseK) * (1.0 + 1.5 * stagnation)).rounded())
        let destroySize = max(2, min(min(15, includedIndices.count), adaptiveK))

        // ALNS-style strategy selection: ask the bandit for a weighted
        // roulette draw rather than a uniform pick. Record the choice so
        // the GA feedback loop can reward/punish it after fitness eval.
        let strategy = context.lnsStrategyBandit.select(rng: context.rng)
        lastDestroyStrategy = strategy

        var destroyedIndices = destroy(
            strategy: strategy,
            includedIndices: includedIndices,
            destroySize: destroySize,
            context: context
        )
        // Fallback to top-priority if the chosen strategy returned nothing
        // (e.g. `day` on an empty-day seed). Guarantees forward progress.
        if destroyedIndices.isEmpty {
            destroyedIndices = destroy(
                strategy: .topPriority,
                includedIndices: includedIndices,
                destroySize: destroySize,
                context: context
            )
        }
        guard !destroyedIndices.isEmpty else { return nil }

        // Repair: full ALNS — let the repair bandit pick between
        // handwritten B&B, regret insertion, and the CP-SAT adapter.
        // Each LNS call samples destroy × repair independently and
        // the two bandits both get a reward update, so after enough
        // calls the product of weights converges on the pair that
        // actually wins on this workload. Previous code hard-routed
        // repair by window size, which worked but left the solver
        // blind to cases where regret would beat B&B on a small
        // window (or B&B would beat CP-SAT on a medium one).
        let cpSATAvailable = context.cpSATRepairer != nil
        let repairStrategy = context.lnsRepairBandit.select(
            rng: context.rng,
            cpSATAvailable: cpSATAvailable
        )
        // Track what actually ran, not just what was selected. The
        // CP-SAT arm can silently fall back to B&B on timeout;
        // rewarding the *selected* arm in that case pollutes the
        // bandit with mis-attributed fitness deltas. The reward
        // feedback in `GeneticAlgorithm.evolveOneGeneration` reads
        // `lastRepairStrategy`, so setting it to the fallback when
        // fallback fires gives the bandit the honest signal.
        let result: IndexSet?
        let actualRepair: LNSRepairStrategy
        switch repairStrategy {
        case .branchAndBound:
            result = cpRepair(destroyed: Set(destroyedIndices), context: context)
            actualRepair = .branchAndBound
        case .regret:
            // `regretRepair` already exists as `cpRepair`'s fallback
            // path — expose it as a top-level choice here so the
            // bandit can try it eagerly. Its "place each gene at
            // its regret-weighted best slot" heuristic is robust
            // on tight weeks where B&B's branching explodes.
            result = regretRepair(destroyed: Set(destroyedIndices), context: context)
            actualRepair = .regret
        case .cpSAT:
            if let repairer = context.cpSATRepairer,
               let cp = applyCPSATRepair(destroyed: destroyedIndices, using: repairer, context: context) {
                result = cp
                actualRepair = .cpSAT
            } else {
                // CP-SAT timed out / adapter nil → fall through to B&B
                // and honestly report "what ran" instead of the
                // selected arm. Without this, a dead CP-SAT path would
                // keep earning reward through B&B's work.
                result = cpRepair(destroyed: Set(destroyedIndices), context: context)
                actualRepair = .branchAndBound
            }
        }
        lastRepairStrategy = actualRepair

        // Tabu bookkeeping: tick the clock and mark the destroyed
        // events as recently moved, so subsequent LNS passes
        // downweight them in destroy selection.
        if let tabu = context.tabuMemory {
            tabu.step()
            let movedIds = destroyedIndices.compactMap { idx -> String? in
                guard idx < genes.count else { return nil }
                return genes[idx].eventId
            }
            tabu.markMoves(eventIds: movedIds)
        }
        return result
    }

}
