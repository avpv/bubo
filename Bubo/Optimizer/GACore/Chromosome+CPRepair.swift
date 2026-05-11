import Foundation

// MARK: - ScheduleChromosome CP-style branch-and-bound repair
//
// Handwritten CP-SAT-lite repair used when no external CP-SAT
// adapter is configured. Extracted from Chromosome+CPSATRepair.swift.

extension ScheduleChromosome {


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

}
