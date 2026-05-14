import Foundation
import BuboDomain

// MARK: - ScheduleChromosome LNS destroy operator
//
// Selects which gene indices to rip out before a CP-SAT or
// branch-and-bound repair pass. Extracted from Chromosome+CPSATRepair.swift.

public extension ScheduleChromosome {


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

}
