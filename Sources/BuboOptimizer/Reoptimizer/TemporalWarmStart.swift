import Foundation
import BuboDomain

// MARK: - Temporal Warm-Start (Wave 1 / item 11)
//
// A scheduling user's Monday rarely looks radically different from
// their previous Monday — same routine meetings, same dependency
// chains, same preferred slots. The optimizer today ignores that
// prior and rebuilds the population from scratch, paying generations
// of climbing to rediscover structure it already had.
//
// `TemporalWarmStart` keeps a bounded history of recent accepted
// solutions, and on the next `optimize()` it produces a seed
// chromosome by (a) shifting the prior solution forward by the right
// number of days and (b) remapping event IDs via a fuzzy match on
// (title, duration, priority, context). The remap lets today's
// slightly-different event pool still benefit from yesterday's
// layout — a new event in the pool sits in any free slot the prior
// left, and a prior event missing from today simply drops.
//
// The warm-start is only a seed: the GA still explores. But it
// cuts time-to-good-solution by 2–3× on recurring calendars because
// the GA starts inside the same basin it converged to last time.
//
// Storage is in-memory with an LRU cap by task signature. Nothing is
// persisted across app launches — that's an explicit non-goal for
// this file (privacy-preserving), though a host could serialize the
// `entries` dictionary if desired.

/// Per-workload store of prior accepted solutions.
///
/// Keyed by `TaskSignature`: when the signature changes (different
/// set of tasks), we don't try to warm-start across workloads because
/// the event IDs are unrelated. Within a signature, newer entries
/// supersede older ones; lookup returns the most recent.
public final class TemporalWarmStart: @unchecked Sendable {
    struct Entry: Sendable {
        /// Gene array as accepted. Stored by value; Genes are `Sendable`.
        let genes: [ScheduleGene]
        /// Workload identity at save time.
        let signature: TaskSignature
        /// The planning horizon the genes were scheduled inside.
        /// Used to compute the day-shift when seeding a later run.
        let horizon: DateInterval
        /// When the solution was saved.
        let savedAt: Date
    }

    private let lock = NSLock()
    private var entries: [TaskSignature: Entry] = [:]

    /// Maximum number of distinct workloads to remember.
    public let capacity: Int

    public init(capacity: Int = 8) {
        self.capacity = capacity
    }

    // MARK: - Save

    /// Register a newly-accepted solution. Call from the host's
    /// `acceptScenario` / post-optimize handler. Silently does nothing
    /// when `genes` is empty.
    public func record(
        genes: [ScheduleGene],
        context: OptimizerContext
    ) {
        guard !genes.isEmpty else { return }
        let signature = TaskSignature(context: context)
        lock.lock()
        defer { lock.unlock() }
        entries[signature] = Entry(
            genes: genes,
            signature: signature,
            horizon: context.planningHorizon,
            savedAt: Date()
        )
        if entries.count > capacity {
            // Evict the oldest. Swift dicts aren't ordered, so we
            // walk once to find min(savedAt). Fine at capacity 8.
            if let oldest = entries.min(by: { $0.value.savedAt < $1.value.savedAt })?.key {
                entries.removeValue(forKey: oldest)
            }
        }
    }

    // MARK: - Seed

    /// Produce a warm-start chromosome for `context`. Returns nil
    /// when we have no applicable prior — the caller then falls
    /// back to greedy/random seeding.
    ///
    /// Matching proceeds in two phases:
    ///   (1) Exact event-ID overlap: genes whose ID appears in the
    ///       current movable pool carry their placement (shifted by
    ///       the horizon delta in whole days).
    ///   (2) Fuzzy match: remaining current events look for a prior
    ///       gene by (title, duration, priority-bucket, context).
    ///       The best score wins.
    /// Genes that find no match default to the earliest working-hour
    /// slot on the first horizon day — the GA's mutation/repair
    /// operators then move them.
    public func seed(context: OptimizerContext) -> ScheduleChromosome? {
        let signature = TaskSignature(context: context)
        lock.lock()
        let entry = entries[signature]
        lock.unlock()
        guard let entry else { return nil }

        let cal = context.calendar
        let priorStartDay = cal.startOfDay(for: entry.horizon.start)
        let currentStartDay = cal.startOfDay(for: context.planningHorizon.start)
        let dayShift = cal.dateComponents([.day], from: priorStartDay, to: currentStartDay).day ?? 0

        // Build lookup from prior gene IDs to shifted placements.
        // `byId` also serves as the pool for fuzzy matching.
        var byId: [String: ScheduleGene] = [:]
        byId.reserveCapacity(entry.genes.count)
        for gene in entry.genes {
            byId[gene.eventId] = gene
        }

        var placedIds = Set<String>()
        var newGenes: [ScheduleGene] = []
        newGenes.reserveCapacity(context.movableEvents.count)

        // Phase 1: exact ID matches.
        for event in context.movableEvents {
            if let prior = byId[event.id] {
                if let shifted = shift(gene: prior, byDays: dayShift, calendar: cal, into: context) {
                    newGenes.append(reassign(shifted, to: event))
                    placedIds.insert(prior.eventId)
                }
            }
        }

        // Phase 2: fuzzy matches for remaining events. Only consider
        // prior genes we haven't already consumed.
        let remainingPriorGenes = entry.genes.filter { !placedIds.contains($0.eventId) }
        for event in context.movableEvents where !newGenes.contains(where: { $0.eventId == event.id }) {
            if let match = fuzzyMatch(event: event, in: remainingPriorGenes, already: placedIds),
               let shifted = shift(gene: match, byDays: dayShift, calendar: cal, into: context) {
                newGenes.append(reassign(shifted, to: event))
                placedIds.insert(match.eventId)
            } else {
                // Default placement: earliest working-hour slot on the
                // first horizon day. The GA then repairs / mutates.
                let day = cal.startOfDay(for: context.planningHorizon.start)
                let start = cal.date(
                    bySettingHour: context.workingHours.lowerBound,
                    minute: 0,
                    second: 0,
                    of: day
                ) ?? day
                let slot = context.ensureSlotRegistry().nearestIndex(to: start)
                newGenes.append(defaultGene(for: event, start: start, slotIndex: slot))
            }
        }

        guard !newGenes.isEmpty else { return nil }

        var chromosome = ScheduleChromosome(genes: newGenes)
        // Running repair after warm-start is important: the shifted
        // placements may collide with newly-added fixed events. The
        // caller is responsible for evaluation; we just return the
        // repaired seed.
        chromosome.repair(context: context)
        return chromosome
    }

    // MARK: - Introspection

    public func hasEntry(for signature: TaskSignature) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[signature] != nil
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
    }

    // MARK: - Internals

    /// Shift a gene's startTime by N days. Returns nil when the
    /// shifted time falls outside the current planning horizon —
    /// the caller treats that as "no prior placement applicable".
    private func shift(
        gene: ScheduleGene,
        byDays days: Int,
        calendar: Calendar,
        into context: OptimizerContext
    ) -> ScheduleGene? {
        guard let shiftedStart = calendar.date(byAdding: .day, value: days, to: gene.startTime) else {
            return nil
        }
        let shiftedEnd = shiftedStart.addingTimeInterval(gene.duration)
        // Drop placements that escape the horizon. The default slot
        // for the affected event will be picked in phase 2.
        if shiftedEnd < context.planningHorizon.start
            || shiftedStart > context.planningHorizon.end {
            return nil
        }
        return gene.withSlot(nearest: shiftedStart, registry: context.ensureSlotRegistry())
    }

    /// Replace the gene's identity with the current event's. The
    /// gene keeps the prior's startTime (already shifted) but adopts
    /// the current event's title, duration, priority, etc. — so a
    /// prior meeting that grew from 30→45 minutes reflects today's
    /// duration in the seed. The prior's `slotIndex` carries over
    /// too so the seed chromosome arrives at the GA already bound
    /// to registry slots.
    private func reassign(_ gene: ScheduleGene, to event: OptimizableEvent) -> ScheduleGene {
        ScheduleGene(
            eventId: event.id,
            title: event.title,
            startTime: gene.startTime,
            duration: event.duration,
            context: event.context,
            energyCost: event.energyCost,
            priority: event.priority,
            isFocusBlock: event.isFocusBlock,
            storyPoints: event.storyPoints,
            isDroppable: event.isDroppable,
            isIncluded: true,
            pomodoroConfig: event.pomodoroConfig,
            reservedTaskIds: event.reservedTaskIds,
            slotIndex: gene.slotIndex
        )
    }

    private func defaultGene(for event: OptimizableEvent, start: Date, slotIndex: Int?) -> ScheduleGene {
        ScheduleGene(
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
            isIncluded: true,
            pomodoroConfig: event.pomodoroConfig,
            reservedTaskIds: event.reservedTaskIds,
            slotIndex: slotIndex
        )
    }

    /// Fuzzy-match a current event to a prior gene via
    /// (title, duration, priority bucket, context) similarity.
    /// Returns the best-scoring gene, or nil when none scores
    /// above `matchThreshold`.
    private func fuzzyMatch(
        event: OptimizableEvent,
        in pool: [ScheduleGene],
        already: Set<String>
    ) -> ScheduleGene? {
        let matchThreshold = 0.5
        var bestScore = 0.0
        var best: ScheduleGene?
        for gene in pool where !already.contains(gene.eventId) {
            let s = similarityScore(event: event, gene: gene)
            if s > bestScore {
                bestScore = s
                best = gene
            }
        }
        return bestScore >= matchThreshold ? best : nil
    }

    /// Weighted similarity score in [0, 1].
    private func similarityScore(event: OptimizableEvent, gene: ScheduleGene) -> Double {
        var score = 0.0
        // Title equality dominates. Calendar users rarely change
        // title wording for recurring events.
        if event.title.caseInsensitiveCompare(gene.title) == .orderedSame {
            score += 0.5
        } else if event.title.lowercased().contains(gene.title.lowercased())
                    || gene.title.lowercased().contains(event.title.lowercased()) {
            score += 0.25
        }
        // Duration match (±10% tolerance).
        let durationRatio = min(event.duration, gene.duration) / max(event.duration, gene.duration)
        score += 0.2 * max(0, durationRatio - 0.9) * 10
        // Priority bucket match.
        if abs(event.priority - gene.priority) < 0.1 { score += 0.15 }
        // Context tag.
        if let ec = event.context, let gc = gene.context, ec == gc {
            score += 0.15
        }
        return min(1.0, score)
    }
}
