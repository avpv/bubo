import Foundation

// MARK: - ScheduleChromosome CP-SAT LNS-repair bridge
//
// `applyCPSATRepair(...)` converts the LNS "destroyed" gene window
// into CP-SAT inputs, drives the in-process branch-and-bound solver
// (`CPSATRepairer`), and writes the resulting assignments back. When
// the solver times out without a complete assignment, the caller in
// `Chromosome+Mutation.swift` falls back to `regretRepair` (also
// defined here).
//
// `cpRepair(...)` is the hand-rolled CP-SAT-lite alternative used
// when the `OptimizerContext.cpSATRepairer` is nil. Combines
// per-variable domains (built via `enumerateFeasibleSlots`), forward
// checking, dom/deg ordering, LP-style bounds, symmetry breaking,
// nogood caching, and restarts — enough of the OR-tools playbook to
// matter at millisecond budgets on the 4-to-20-event plan-week
// workload.
//
// Extracted from `Chromosome.swift`; visibility changes documented
// at the call sites in `Chromosome.swift`:
//   • `OccupiedInterval` was `fileprivate`, now internal.
//   • `findFirstFreeSlot`, `findLastFreeSlot`, `enumerateFeasibleSlots`
//     dropped `private` (now internal) so this file can call them.
//   • `applyCPSATRepair`, `destroy`, `cpRepair`, `regretRepair`
//     dropped `private` in a prior round so `applyLNS` in
//     `Chromosome+Mutation.swift` can drive this pipeline.

extension ScheduleChromosome {

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

    /// Execute one destroy strategy, returning the indices to rip out.
    /// Each branch is self-contained and produces up to `destroySize`
    /// indices from `includedIndices`. Non-mutating — destruction happens
    /// implicitly later by excluding these from the occupied set.
    ///
    /// Internal (was `private`) — called from `applyLNS(...)` in
    /// `Chromosome+Mutation.swift`.
    func destroy(
        strategy: LNSDestroyStrategy,
        includedIndices: [Int],
        destroySize: Int,
        context: OptimizerContext
    ) -> [Int] {
        switch strategy {
        case .day:
            let byDay = Dictionary(grouping: includedIndices) {
                context.calendar.startOfDay(for: genes[$0].startTime)
            }
            let days = Array(byDay.keys)
            guard !days.isEmpty else { return [] }
            let chosen = days[context.rng.int(in: 0..<days.count)]
            return byDay[chosen] ?? []

        case .topPriority:
            // Priority first; ties broken by backlog position so identical
            // tasks are always destroyed in the same order the user dragged
            // them in. Without the tiebreaker, LNS repeats across generations
            // sampled different permutations of equal-priority tasks, which
            // propagated into the final schedule.
            let backlogIdx = context.backlogIndexMap()
            return includedIndices
                .sorted { a, b in
                    let pa = genes[a].priority
                    let pb = genes[b].priority
                    if pa != pb { return pa > pb }
                    let ia = backlogIdx[genes[a].eventId]
                    let ib = backlogIdx[genes[b].eventId]
                    switch (ia, ib) {
                    case let (.some(x), .some(y)): return x < y
                    case (.some, .none): return true
                    case (.none, .some): return false
                    case (.none, .none): return false
                    }
                }
                .prefix(destroySize)
                .map { $0 }

        case .random:
            // Tabu-weighted sampling. Each remaining index gets a
            // weight from the tabu memory (1.0 if no memory wired,
            // otherwise penalised for recent moves and over-touched
            // events). Selection is roulette-wheel.
            var pool = includedIndices
            var picked: [Int] = []
            picked.reserveCapacity(destroySize)
            let tabu = context.tabuMemory
            for _ in 0..<min(destroySize, pool.count) {
                let weights = pool.map { idx -> Double in
                    guard let tabu else { return 1.0 }
                    return tabu.score(eventId: genes[idx].eventId)
                }
                let total = weights.reduce(0, +)
                let pickedJ: Int
                if total <= 1e-9 {
                    pickedJ = context.rng.int(in: 0..<pool.count)
                } else {
                    let target = context.rng.double(in: 0..<total)
                    var running = 0.0
                    var foundAt = pool.count - 1
                    for (idx, w) in weights.enumerated() {
                        running += w
                        if running >= target {
                            foundAt = idx
                            break
                        }
                    }
                    pickedJ = foundAt
                }
                picked.append(pool[pickedJ])
                pool.swapAt(pickedJ, pool.count - 1)
                pool.removeLast()
            }
            return picked

        case .relatedContext:
            // Seed a random gene; pull in siblings sharing its context
            // tag. If the seed has no tag, fall back to priority within
            // ±0.1 of the seed — gives "related by importance" behaviour.
            let seedIdx = includedIndices[context.rng.int(in: 0..<includedIndices.count)]
            let seedGene = genes[seedIdx]
            let candidates: [Int]
            if let seedCtx = seedGene.context {
                candidates = includedIndices.filter { genes[$0].context == seedCtx }
            } else {
                let seedP = seedGene.priority
                candidates = includedIndices.filter { abs(genes[$0].priority - seedP) <= 0.1 }
            }
            var ordered = [seedIdx]
            for idx in candidates where idx != seedIdx {
                ordered.append(idx)
                if ordered.count >= destroySize { break }
            }
            return ordered

        case .worstFit:
            let eventById: [String: OptimizableEvent] = Dictionary(
                uniqueKeysWithValues: context.movableEvents.map { ($0.id, $0) }
            )
            let cal = context.calendar
            var scored: [(idx: Int, score: Double)] = []
            scored.reserveCapacity(includedIndices.count)
            for i in includedIndices {
                let gi = genes[i]
                var s = 0.0
                // Overlap with fixed events
                for f in context.fixedEvents where gi.startTime < f.endDate && f.startDate < gi.endTime {
                    s += 1.0
                }
                // Overlap with other movable genes (halved to avoid
                // double-counting when both ends sit on an overlap pair)
                for j in includedIndices where j != i {
                    let gj = genes[j]
                    if gi.startTime < gj.endTime && gj.startTime < gi.endTime {
                        s += 0.5
                    }
                }
                // Deadline miss
                if let dl = eventById[gi.eventId]?.deadline, gi.endTime > dl {
                    s += 2.0
                }
                // Start outside working hours
                let hour = cal.component(.hour, from: gi.startTime)
                if hour < context.workingHours.lowerBound || hour > context.workingHours.upperBound {
                    s += 0.5
                }
                scored.append((i, s))
            }
            scored.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                return genes[a.idx].priority > genes[b.idx].priority
            }
            return scored.prefix(destroySize).map { $0.idx }
        }
    }

    /// Budgeted CP-style branch-and-bound repair with forward checking
    /// and dom/deg variable ordering.
    ///
    /// For each destroyed gene we enumerate up to 6 feasible slot
    /// candidates sorted by `enumerateFeasibleSlots`'s fitness-tracking
    /// cost proxy. The search then:
    ///
    /// - **Dynamically picks the next variable** by smallest remaining
    ///   domain (fail-first), breaking ties by destroyed-dependent
    ///   count (most-constraining-first) then priority desc. This is
    ///   the classic CP `dom/deg` heuristic — variables most likely to
    ///   cause failure get checked first, so dead branches cut earlier.
    /// - **Applies forward checking after every placement**, filtering
    ///   overlap-conflicting and dependency-violating slots out of
    ///   every other unassigned variable's domain. When any
    ///   non-droppable variable's domain empties, the branch fails
    ///   immediately without descending.
    /// - **Respects topological precedence via in-degree gating**: a
    ///   variable only enters the ready set once all its destroyed
    ///   predecessors have been placed (or dropped).
    /// - **Prunes by accumulated cost**: branches whose partial cost
    ///   already exceeds the best complete solution skip expansion.
    ///
    /// Budget is capped at `maxExpansions` nodes. When exhausted without
    /// any complete solution, we fall back to `regretRepair` so the LNS
    /// call never returns worse output than before.
    ///
    /// Droppable genes get a synthetic "drop" branch with a penalty cost
    /// — heavy enough to prefer placement but finite, so infeasible-only
    /// instances can still converge.
    ///
    /// Additionally:
    /// - **Nogood cache**: when forward checking fails after placing
    ///   variable V at slot S with a given prefix of previously-placed
    ///   variables, the `(prefix-hash, V, S)` triple is recorded. Later
    ///   branches reaching the same prefix skip the bad candidate
    ///   without re-running FC. Not full conflict analysis (no
    ///   generalisation across prefixes), but catches the repeated
    ///   dead-end pattern that shows up when symmetries aren't fully
    ///   broken.
    /// - **Restart loop**: up to three attempts with geometric segment
    ///   budgets (256, 512, 1024) and per-attempt reshuffled candidate
    ///   orderings. Best solution and nogoods persist across restarts.
    ///   The first attempt dominates on easy instances; later ones
    ///   kick in only when the initial cost landscape misled greedy
    ///   descent.
    ///
    /// Not a full CP-SAT — Swift has no native CP solver, and building
    /// one that matches OR-Tools would mean reimplementing thousands of
    /// lines of conflict analysis, LP relaxation, and presolve. The
    /// pragmatic bound for this codebase is a SwiftPM binding to
    /// OR-Tools via its C++ API. What we have here stacks the
    /// techniques that matter most for scheduling LNS repair at
    /// millisecond budgets: per-variable domains, forward checking,
    /// dom/deg ordering, LP-style bounds, symmetry breaking, nogood
    /// caching, restarts.
    // Internal (was `private`) — called from `applyLNS(...)` in
    // `Chromosome+Mutation.swift`.
    mutating func cpRepair(
        destroyed: Set<Int>,
        context: OptimizerContext
    ) -> IndexSet? {
        let cal = context.calendar
        let horizon = context.planningHorizon
        let slotRegistry = context.ensureSlotRegistry()

        var baseOccupied: [(start: Date, end: Date)] = context.fixedEvents.map {
            ($0.startDate, $0.endDate)
        }
        // Parallel rich-metadata list, used only by the domain-cost
        // proxy so it can score ContextSwitch, BreakPlacement, and
        // WeekBalance. Forward checking and overlap-time comparisons
        // keep using the lean tuple list above — the metadata wouldn't
        // change any of those decisions.
        var baseOccupiedRich: [OccupiedInterval] = context.fixedEvents.map {
            OccupiedInterval(
                start: $0.startDate,
                end: $0.endDate,
                context: $0.context,
                isFocusBlock: false
            )
        }
        for (j, gene) in genes.enumerated() where gene.isIncluded && !destroyed.contains(j) {
            baseOccupied.append((gene.startTime, gene.endTime))
            baseOccupiedRich.append(OccupiedInterval(
                start: gene.startTime,
                end: gene.endTime,
                context: gene.context,
                isFocusBlock: gene.isFocusBlock
            ))
        }
        baseOccupied.sort { $0.start < $1.start }
        baseOccupiedRich.sort { $0.start < $1.start }

        let eventById: [String: OptimizableEvent] = Dictionary(
            uniqueKeysWithValues: context.movableEvents.map { ($0.id, $0) }
        )
        let genesByEvent: [String: Int] = Dictionary(
            uniqueKeysWithValues: genes.enumerated().map { ($1.eventId, $0) }
        )

        // Topological order over the destroyed subset.
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
        // Note: variable ordering is now dynamic (dom/deg heuristic inside
        // dfs) rather than a fixed topological permutation. The in-degree
        // map above stays — it gates which variables are "ready" at each
        // node — but we no longer flatten it into an `order` array.
        // Keeping a copy of initial in-degrees so the search can restore
        // them on backtrack without recomputing.
        let initialInDegree = inDegree

        // Reverse-dependency deadlines (destroyed Y with non-destroyed
        // dependent X): Y.end ≤ X.start.
        var reverseDeadline: [Int: Date] = [:]
        for (j, g) in genes.enumerated() where g.isIncluded && !destroyed.contains(j) {
            guard let ev = eventById[g.eventId] else { continue }
            for depId in ev.dependsOn {
                guard let depIdx = genesByEvent[depId], destroyed.contains(depIdx) else { continue }
                let cur = reverseDeadline[depIdx] ?? .distantFuture
                if g.startTime < cur { reverseDeadline[depIdx] = g.startTime }
            }
        }

        // Per-gene domain. Top-6 lets BnB explore meaningful alternatives
        // without blowing up. On an average weekly workload this yields
        // 4-6 candidates per gene (most have fewer feasible slots than 6
        // anyway due to deadline/dependency constraints).
        let domainSize = 6
        var domains: [Int: [(slot: Date, cost: Double)]] = [:]
        for idx in destroyed {
            let event = eventById[genes[idx].eventId]
            let origDL = event?.deadline
            let revDL = reverseDeadline[idx]
            let deadline: Date?
            if let o = origDL, let r = revDL { deadline = min(o, r) }
            else if let o = origDL { deadline = o }
            else if let r = revDL { deadline = r }
            else { deadline = nil }

            domains[idx] = Self.enumerateFeasibleSlots(
                duration: genes[idx].duration,
                topK: domainSize,
                preferredHours: event?.preferredHourRange,
                occupied: baseOccupiedRich,
                horizon: horizon,
                workingHours: context.workingHours,
                calendar: cal,
                earliestStart: event?.earliestStart,
                deadline: deadline,
                dependsOn: event?.dependsOn ?? [],
                placedGenes: genes,
                energyCost: genes[idx].energyCost,
                isFocusBlock: genes[idx].isFocusBlock,
                geneContext: genes[idx].context,
                preferences: context.preferences
            )
        }

        // Symmetry breaking. Two destroyed genes are treated as
        // equivalent when they share every property that would make
        // their placements exchangeable — duration, quantised priority,
        // deadline, preferred hours, dependency set, context,
        // focus-block flag, and quantised energy cost. For each
        // equivalence class we designate the smallest gene-index as
        // the "canonical" one; other class members are forced to come
        // AFTER the canonical one in the placement order AND to land
        // at a slot >= the canonical placement. This collapses the
        // N! placement permutations of a size-N class into a single
        // branch, reclaiming a big chunk of the BnB budget on the
        // (rare but sharp) occasions when the user has a batch of
        // near-identical tasks.
        struct GeneSignature: Hashable {
            let duration: TimeInterval
            let priorityQ: Int
            let deadline: Date?
            let preferredHours: ClosedRange<Int>?
            let dependsOnKey: String
            let energyQ: Int
            let context: String?
            let isFocusBlock: Bool
        }
        var symPredecessor: [Int: Int] = [:]
        var signatureSeen: [GeneSignature: Int] = [:]
        for idx in destroyed.sorted() {
            let ev = eventById[genes[idx].eventId]
            let sig = GeneSignature(
                duration: genes[idx].duration,
                priorityQ: Int((genes[idx].priority * 100).rounded()),
                deadline: ev?.deadline,
                preferredHours: ev?.preferredHourRange,
                dependsOnKey: (ev?.dependsOn ?? []).sorted().joined(separator: ","),
                energyQ: Int((genes[idx].energyCost * 100).rounded()),
                context: genes[idx].context,
                isFocusBlock: genes[idx].isFocusBlock
            )
            if let canonical = signatureSeen[sig], canonical != idx {
                symPredecessor[idx] = canonical
            } else {
                signatureSeen[sig] = idx
                symPredecessor[idx] = idx
            }
        }

        // Search state. Mutable; captured by the nested dfs.
        var expansions = 0
        let maxExpansions = 2000
        // Per-segment budget for restart-style search: dfs checks this
        // in addition to `maxExpansions`, so the outer restart loop can
        // cap each attempt to its slice of the total budget.
        var expansionsThisSegment = 0
        var segmentLimit = 256
        var currentPlacements: [Int: Date] = [:]
        var currentOccupied = baseOccupied
        var currentDrops: Set<Int> = []

        // Nogood cache: remembers (path-signature, var, slot) triples
        // that led to a forward-checking dead-end. Before trying a
        // candidate we check whether the SAME path prefix + candidate
        // has already failed; if so we skip it without re-running FC.
        // Not full conflict analysis (no implication-graph generalisation)
        // but catches the common "search rediscovers the same dead-end
        // via a symmetric permutation" waste. Hash collisions are benign
        // — worst case we skip a candidate we shouldn't have, wasting
        // one FC call on a later path.
        struct NogoodKey: Hashable {
            let pathHash: Int
            let idx: Int
            let slot: Date
        }
        var nogoods: Set<NogoodKey> = []
        func currentPathHash() -> Int {
            var hasher = Hasher()
            for key in currentPlacements.keys.sorted() {
                hasher.combine(key)
                hasher.combine(currentPlacements[key]!)
            }
            for drop in currentDrops.sorted() {
                hasher.combine(-drop - 1)
            }
            return hasher.finalize()
        }
        var currentCost = 0.0
        var bestPlacements: [Int: Date] = [:]
        var bestDrops: Set<Int> = []
        var bestCost = Double.infinity
        var bestFound = false

        // CP state: mutable per-variable remaining domain + live in-degree.
        // Snapshotted on every branch entry and restored on backtrack —
        // this is the mechanism that makes forward checking "temporary"
        // relative to the current search path.
        var remainingDomains = domains
        var livedInDegree = initialInDegree

        // Drop penalty scales with gene priority so the solver prefers
        // keeping high-importance genes even when cheaper slots exist
        // for low-importance ones. Range is 10 (priority 0) to 15
        // (priority 1). Covers the TaskInclusion objective without
        // needing its per-chromosome breakdown.
        func dropCostFor(_ idx: Int) -> Double {
            10.0 + 5.0 * genes[idx].priority
        }

        // LP-style lower bound on the remaining cost at the current
        // search node. For every still-unassigned destroyed gene we
        // take the smaller of its cheapest remaining domain slot and
        // its drop penalty (if droppable). The sum is an admissible
        // lower bound because every gene must either land at a slot
        // (min cost = domain head) or drop (cost = drop penalty). We
        // never overestimate; we never under-prune when a better
        // `bestCost` exists.
        func remainingLowerBound() -> Double {
            var lb = 0.0
            for idx in destroyed {
                if currentPlacements.keys.contains(idx) { continue }
                if currentDrops.contains(idx) { continue }
                let domainMin = remainingDomains[idx]?.first?.cost ?? .infinity
                if genes[idx].isDroppable {
                    lb += min(domainMin, dropCostFor(idx))
                } else if domainMin.isFinite {
                    lb += domainMin
                } else {
                    // Non-droppable with empty domain — forward check
                    // should've killed the branch earlier; treat as
                    // infinitely expensive to force immediate pruning.
                    return .infinity
                }
            }
            return lb
        }

        // Forward checking: after committing `placedIdx` to `placedSlot`,
        // filter every other unassigned variable's remaining domain to
        // drop slots that now conflict.
        //
        // Three conflict classes are pruned eagerly:
        //   1. Overlap with the newly-placed interval.
        //   2. Forward dependency: if `idx` depends on `placedIdx`, every
        //      remaining candidate for `idx` must start no earlier than
        //      `placedSlot + placedDuration`.
        //   3. Reverse dependency: if `placedIdx` depends on `idx`, every
        //      remaining candidate for `idx` must end no later than
        //      `placedSlot`.
        //
        // Returns `false` when any non-droppable variable's domain empties,
        // which aborts the current branch without descending — this is the
        // "dead-end" detection that distinguishes CP forward checking from
        // lazy placement-time overlap checks.
        func forwardCheck(placedIdx: Int, placedSlot: Date, placedEnd: Date) -> Bool {
            let placedEventId = genes[placedIdx].eventId
            let placedEvent = eventById[placedEventId]
            for idx in destroyed {
                if idx == placedIdx { continue }
                if currentPlacements.keys.contains(idx) { continue }
                if currentDrops.contains(idx) { continue }

                let ev = eventById[genes[idx].eventId]
                let idxDuration = genes[idx].duration
                let idxDependsOnPlaced = ev?.dependsOn.contains(placedEventId) ?? false
                let placedDependsOnIdx = placedEvent?.dependsOn.contains(genes[idx].eventId) ?? false

                var remaining = remainingDomains[idx] ?? []
                remaining.removeAll { cand in
                    let cEnd = cand.slot.addingTimeInterval(idxDuration)
                    if cand.slot < placedEnd && cEnd > placedSlot { return true }
                    if idxDependsOnPlaced && cand.slot < placedEnd { return true }
                    if placedDependsOnIdx && cEnd > placedSlot { return true }
                    return false
                }
                remainingDomains[idx] = remaining

                // Dead end: a non-droppable variable with no valid slot
                // can't complete. Signal failure immediately.
                if remaining.isEmpty && !genes[idx].isDroppable { return false }
            }
            return true
        }

        // dom/deg: pick the unassigned, ready variable (livedInDegree=0)
        // with the smallest remaining domain. Ties break by in-degree of
        // destroyed dependents (most-constraining-first), then by priority
        // desc, and finally by backlog position so genes the user dragged
        // to the top of the backlog commit first when everything else is
        // equal — matches the downstream `BacklogOrderObjective`'s
        // preference instead of leaving the order to iteration chance.
        //
        // Symmetry: skip a variable whose canonical-sym-predecessor is
        // still unassigned. This forces equivalent genes to commit in
        // a fixed (increasing-index) order, pruning the N!-way
        // redundancy.
        let backlogIdx = context.backlogIndexMap()
        func backlogRank(_ idx: Int) -> Int {
            // Genes without a backlog position (calendar-derived) fall to
            // the end of the tie-break so they never displace backlog
            // tasks whose order the user explicitly chose.
            backlogIdx[genes[idx].eventId] ?? Int.max
        }
        func pickNextVariable() -> Int? {
            var best: (idx: Int, size: Int, deg: Int, prio: Double, backlog: Int)? = nil
            for idx in destroyed {
                if currentPlacements.keys.contains(idx) { continue }
                if currentDrops.contains(idx) { continue }
                if (livedInDegree[idx] ?? 0) > 0 { continue }
                if let sp = symPredecessor[idx], sp != idx,
                   !currentPlacements.keys.contains(sp),
                   !currentDrops.contains(sp) {
                    continue
                }
                let size = (remainingDomains[idx] ?? []).count
                let deg = destroyedDependents[idx]?.count ?? 0
                let prio = genes[idx].priority
                let backlog = backlogRank(idx)
                if let cur = best {
                    let tighter = size < cur.size
                    let sizeTie = size == cur.size
                    let moreConstraining = deg > cur.deg
                    let degTie = deg == cur.deg
                    let higherPrio = prio > cur.prio
                    let prioTie = prio == cur.prio
                    let earlierBacklog = backlog < cur.backlog
                    if tighter
                        || (sizeTie && moreConstraining)
                        || (sizeTie && degTie && higherPrio)
                        || (sizeTie && degTie && prioTie && earlierBacklog)
                    {
                        best = (idx, size, deg, prio, backlog)
                    }
                } else {
                    best = (idx, size, deg, prio, backlog)
                }
            }
            return best?.idx
        }

        func dfs() {
            if expansions >= maxExpansions { return }
            if expansionsThisSegment >= segmentLimit { return }
            if currentCost >= bestCost { return }
            if currentCost + remainingLowerBound() >= bestCost { return }

            // Complete: every destroyed gene assigned or dropped.
            if currentPlacements.count + currentDrops.count == destroyed.count {
                bestPlacements = currentPlacements
                bestDrops = currentDrops
                bestCost = currentCost
                bestFound = true
                return
            }
            expansions += 1
            expansionsThisSegment += 1

            guard let chosenIdx = pickNextVariable() else {
                // No ready variable: either a cycle or inDegree bookkeeping
                // is stuck. Bail; caller falls back to regret insertion.
                return
            }

            let event = eventById[genes[chosenIdx].eventId]
            let duration = genes[chosenIdx].duration

            // Re-compute placement floor here. FC has pruned slots that
            // violate overlap / forward-dep / reverse-dep; the floor
            // check below covers the fixed-calendar / non-destroyed
            // predecessor case FC can't touch (those aren't variables).
            var floor = event?.earliestStart ?? horizon.start
            if floor < horizon.start { floor = horizon.start }
            if let event {
                for depId in event.dependsOn {
                    if let depIdx = genesByEvent[depId] {
                        if let placedSlot = currentPlacements[depIdx] {
                            floor = max(floor, placedSlot.addingTimeInterval(genes[depIdx].duration))
                        } else if !destroyed.contains(depIdx), genes[depIdx].isIncluded {
                            floor = max(floor, genes[depIdx].endTime)
                        }
                    }
                }
            }

            // Symmetry slot constraint: when chosenIdx is NOT its own
            // canonical sym-predecessor, its earliest allowed slot is
            // the canonical's placement — otherwise we'd explore the
            // "swap A and B" duplicate of a branch we already did.
            let symSlotFloor: Date?
            if let sp = symPredecessor[chosenIdx], sp != chosenIdx,
               let spSlot = currentPlacements[sp] {
                symSlotFloor = spSlot
            } else {
                symSlotFloor = nil
            }

            // Compute path hash ONCE for this depth; same value for every
            // candidate we try below because the partial assignment
            // hasn't changed yet.
            let pathHash = currentPathHash()

            // Try placement candidates from the (possibly-pruned) domain.
            for (slot, slotCost) in (remainingDomains[chosenIdx] ?? []) {
                if expansions >= maxExpansions { return }
                if slot < floor { continue }
                if let symFloor = symSlotFloor, slot < symFloor { continue }
                // Nogood check: skip if this exact (path-prefix, var, slot)
                // has already been proven dead-end earlier in the search.
                let ngKey = NogoodKey(pathHash: pathHash, idx: chosenIdx, slot: slot)
                if nogoods.contains(ngKey) { continue }

                let end = slot.addingTimeInterval(duration)
                let hasOverlap = currentOccupied.contains { occ in
                    slot < occ.end && end > occ.start
                }
                if hasOverlap { continue }

                let newCost = currentCost + slotCost
                if newCost >= bestCost { continue }

                let domainsSnap = remainingDomains
                let inDegreeSnap = livedInDegree
                let savedCost = currentCost

                currentPlacements[chosenIdx] = slot
                currentOccupied.append((slot, end))
                currentCost = newCost
                for dep in destroyedDependents[chosenIdx] ?? [] {
                    livedInDegree[dep, default: 0] -= 1
                }

                let fcOK = forwardCheck(placedIdx: chosenIdx, placedSlot: slot, placedEnd: end)
                if fcOK {
                    dfs()
                } else {
                    // Remember this dead-end so future paths reaching the
                    // same prefix skip straight past the failing candidate.
                    nogoods.insert(ngKey)
                }

                currentCost = savedCost
                currentOccupied.removeLast()
                currentPlacements.removeValue(forKey: chosenIdx)
                remainingDomains = domainsSnap
                livedInDegree = inDegreeSnap
            }

            // Drop branch for droppable genes. The drop isn't a placement
            // so FC has nothing to prune — we just mark and descend.
            // Drop cost scales with the gene's priority so the search
            // prefers keeping high-priority genes even when dropping a
            // lower-priority gene would be cheaper.
            if genes[chosenIdx].isDroppable {
                let dropCost = dropCostFor(chosenIdx)
                let newCost = currentCost + dropCost
                if newCost < bestCost {
                    let domainsSnap = remainingDomains
                    let inDegreeSnap = livedInDegree
                    let savedCost = currentCost

                    currentDrops.insert(chosenIdx)
                    currentCost = newCost
                    for dep in destroyedDependents[chosenIdx] ?? [] {
                        livedInDegree[dep, default: 0] -= 1
                    }

                    dfs()

                    currentCost = savedCost
                    currentDrops.remove(chosenIdx)
                    remainingDomains = domainsSnap
                    livedInDegree = inDegreeSnap
                }
            }
        }

        // Restart loop. Up to three attempts, each capped by a growing
        // segment budget (256, 512, 1024). Between attempts we
        // reshuffle per-gene candidate orderings so the next pass dives
        // into a genuinely different region of the search tree. Best
        // solution (`bestPlacements`, `bestCost`, `bestFound`) and the
        // nogood cache persist across restarts, so accumulated learning
        // isn't thrown away.
        //
        // Not full Luby — geometric is simpler and good enough at the
        // ms-scale budget we run on. The first segment dominates when
        // the problem is easy; later ones kick in only for
        // pathologically hard instances where the initial cost ordering
        // led greedy descent into a bad basin.
        let initialDomains = domains
        let rng = context.rng
        var attempt = 0
        while expansions < maxExpansions && attempt < 3 {
            if attempt > 0 {
                // Reshuffle all domains; reset mutable search state.
                for idx in initialDomains.keys {
                    var shuffled = initialDomains[idx] ?? []
                    rng.shuffle(&shuffled)
                    domains[idx] = shuffled
                }
            }
            remainingDomains = domains
            livedInDegree = initialInDegree
            currentPlacements.removeAll(keepingCapacity: true)
            currentOccupied = baseOccupied
            currentDrops.removeAll(keepingCapacity: true)
            currentCost = 0
            expansionsThisSegment = 0

            dfs()

            attempt += 1
            segmentLimit = min(segmentLimit * 2, maxExpansions - expansions)
            if segmentLimit <= 0 { break }
        }

        // Budget exhausted with no complete solution → fall back to
        // regret insertion. Guarantees forward progress regardless of
        // how pathological the domain is.
        guard bestFound else {
            return regretRepair(destroyed: destroyed, context: context)
        }

        var changed = IndexSet()
        for idx in destroyed {
            if bestDrops.contains(idx) {
                if genes[idx].isIncluded {
                    genes[idx].isIncluded = false
                    changed.insert(idx)
                }
            } else if let slot = bestPlacements[idx] {
                if genes[idx].startTime != slot {
                    genes[idx] = genes[idx].withSlot(nearest: slot, registry: slotRegistry)
                    changed.insert(idx)
                }
            }
        }
        return changed.isEmpty ? nil : changed
    }

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
