import Foundation

// MARK: - Chromosome Protocol

/// A generic chromosome for the genetic algorithm.
///
/// Hashable conformance is required so the GA can detect duplicate individuals
/// in O(N) via a Set lookup rather than O(N²) via pairwise Equatable. Every
/// concrete chromosome in this codebase already has Hashable-ready fields
/// (genes, sequence, …) so implementing `hash(into:)` is a one-liner.
protocol Chromosome: Hashable {
    var fitness: Double { get set }

    /// Raw fitness before any diversity adjustments (fitness sharing, niching).
    /// Equals `fitness` unless fitness sharing has reduced the visible fitness
    /// for selection pressure. `bestEver` tracking must use `rawFitness` so that
    /// a globally-best-but-crowded individual isn't lost to a sharing-penalized score.
    var rawFitness: Double { get set }

    /// Create a random chromosome within the given context.
    static func random(context: OptimizerContext) -> Self

    /// Create a heuristically-seeded chromosome using greedy placement.
    /// Returns a feasible (or near-feasible) starting point for the GA.
    static func greedy(context: OptimizerContext) -> Self

    /// Produce two offspring via crossover with another chromosome.
    func crossover(with other: Self, context: OptimizerContext) -> (Self, Self)

    /// Produce two offspring via crossover using a specific strategy.
    func crossover(with other: Self, strategy: CrossoverStrategy, context: OptimizerContext) -> (Self, Self)

    /// Apply random mutations at the given rate.
    mutating func mutate(rate: Double, context: OptimizerContext)

    /// Repair constraint violations in-place (e.g. fix overlaps, clamp to working hours).
    mutating func repair(context: OptimizerContext)

    /// Genotypic distance to another chromosome, normalized to [0, 1].
    /// Used for diversity measurement, crowding, and fitness sharing.
    func distance(to other: Self) -> Double
}

extension Chromosome {
    /// Default: ignore strategy, fall back to the basic crossover.
    func crossover(with other: Self, strategy: CrossoverStrategy, context: OptimizerContext) -> (Self, Self) {
        crossover(with: other, context: context)
    }

    /// Default no-op repair for chromosomes without constraint awareness.
    mutating func repair(context: OptimizerContext) {}

    /// Default greedy falls back to random.
    static func greedy(context: OptimizerContext) -> Self {
        random(context: context)
    }

    /// Default distance: 0 if equal, 1 otherwise.
    func distance(to other: Self) -> Double {
        self == other ? 0 : 1
    }
}

// MARK: - Schedule Chromosome

/// A chromosome representing a complete schedule assignment.
/// Each gene maps one movable event to a specific time slot.
struct ScheduleChromosome: Chromosome, Sendable {
    var genes: [ScheduleGene]
    var fitness: Double = 0.0
    var rawFitness: Double = 0.0

    /// Tracks whether this chromosome needs fitness re-evaluation.
    /// Set to true on creation, crossover, and mutation; cleared after evaluation.
    var needsEvaluation: Bool = true

    /// Cached per-objective scores for incremental evaluation.
    /// Populated after full evaluation; reused when only a subset of genes change.
    var objectiveCache: [String: Double]?

    /// Per-day breakdown for `DayPartitionedObjective` instances. Keys are
    /// objective names; values are `[dayStart: dayScore]`. When delta evaluation
    /// runs, only days that contain mutated genes (or used to, before the
    /// mutation) are rescored — unaffected days are read from this cache.
    var perDayObjectiveCache: [String: [Date: Double]]?

    /// For each gene position, the day it sat on the last time this chromosome
    /// was fully evaluated. Used to spot "a gene moved from day X to day Y"
    /// and mark both X and Y as dirty, so per-day delta evaluation doesn't
    /// leave stale scores on abandoned days. `nil` means "no prior evaluation"
    /// and forces a full pass.
    var geneDaysSnapshot: [Date]?

    /// Indices of genes that were modified since last evaluation.
    /// Used by delta evaluation to skip recomputing unaffected local objectives.
    var mutatedGeneIndices: IndexSet?

    /// Equality ignores needsEvaluation and caches — two chromosomes with the same genes and fitness are equal.
    static func == (lhs: ScheduleChromosome, rhs: ScheduleChromosome) -> Bool {
        lhs.genes == rhs.genes && lhs.fitness == rhs.fitness
    }

    /// Hash the same fields used by `==`. Keeping this in sync with equality is
    /// a Hashable invariant; `fitness` is quantized to 4 decimal places so
    /// float noise between otherwise-identical chromosomes doesn't produce
    /// accidental hash divergence that would defeat duplicate detection.
    func hash(into hasher: inout Hasher) {
        hasher.combine(genes)
        hasher.combine(Int64((fitness * 10_000).rounded()))
    }

    // MARK: - Random Initialization

    static func random(context: OptimizerContext) -> ScheduleChromosome {
        let cal = context.calendar
        let genes = context.movableEvents.map { event -> ScheduleGene in
            let start = randomStartTime(
                for: event,
                in: context.planningHorizon,
                workingHours: context.workingHours,
                calendar: cal,
                rng: context.rng
            )
            // Droppable genes start with ~70% chance of inclusion
            // so the GA explores both including and excluding them.
            let included = event.isDroppable ? context.rng.bool(probability: 0.7) : true
            return ScheduleGene(
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
                isIncluded: included
            )
        }
        return ScheduleChromosome(genes: genes, needsEvaluation: true)
    }

    // MARK: - Greedy Initialization

    /// Build a feasible chromosome by greedily placing events one at a time
    /// into the first available slot, sorted by priority/deadline urgency.
    /// Produces high-quality seed individuals that give the GA a strong starting point.
    static func greedy(context: OptimizerContext) -> ScheduleChromosome {
        let cal = context.calendar

        // Sort events: higher priority first, then earlier deadline, then shorter duration
        let sortedEvents = context.movableEvents.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            if let da = a.deadline, let db = b.deadline { return da < db }
            if a.deadline != nil { return true }
            if b.deadline != nil { return false }
            return a.duration < b.duration
        }

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
                genesByEvent: genesByEvent
            )

            let isIncluded: Bool
            if slot != nil {
                isIncluded = true
            } else {
                isIncluded = !event.isDroppable
            }

            let startTime = slot ?? randomStartTime(
                for: event,
                in: context.planningHorizon,
                workingHours: context.workingHours,
                calendar: cal,
                rng: context.rng
            )

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
                isIncluded: isIncluded
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
            let start = randomStartTime(for: event, in: context.planningHorizon, workingHours: context.workingHours, calendar: cal, rng: context.rng)
            result.append(ScheduleGene(
                eventId: event.id, title: event.title, startTime: start,
                duration: event.duration, context: event.context, energyCost: event.energyCost,
                priority: event.priority, isFocusBlock: event.isFocusBlock,
                storyPoints: event.storyPoints, isDroppable: event.isDroppable, isIncluded: !event.isDroppable
            ))
        }

        return ScheduleChromosome(genes: result, needsEvaluation: true)
    }

    /// Find the first gap in the schedule that fits the event duration.
    private static func findFirstFreeSlot(
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
        genesByEvent: [String: Int]
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

        // Try each day, preferring preferred hours
        for dayOffset in 0..<daysInHorizon {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: horizonStartDay) else { continue }
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

    // MARK: - Crossover (Order-based)

    func crossover(with other: ScheduleChromosome, context: OptimizerContext) -> (ScheduleChromosome, ScheduleChromosome) {
        guard genes.count > 1, genes.count == other.genes.count else { return (self, other) }

        let point = context.rng.int(in: 1..<genes.count)

        var child1Genes = Array(genes[..<point])
        var child2Genes = Array(other.genes[..<point])

        // Fill remaining genes from the other parent — swap time slots
        for i in point..<genes.count {
            child1Genes.append(genes[i].withStartTime(other.genes[i].startTime))
            child2Genes.append(other.genes[i].withStartTime(genes[i].startTime))
        }

        return (
            ScheduleChromosome(genes: child1Genes, needsEvaluation: true),
            ScheduleChromosome(genes: child2Genes, needsEvaluation: true)
        )
    }

    /// Strategy-aware crossover that delegates to the Crossover enum.
    func crossover(with other: ScheduleChromosome, strategy: CrossoverStrategy, context: OptimizerContext) -> (ScheduleChromosome, ScheduleChromosome) {
        Crossover.perform(self, other, strategy: strategy, context: context)
    }

    // MARK: - Mutation

    mutating func mutate(rate: Double, context: OptimizerContext) {
        needsEvaluation = true
        var changed = IndexSet()
        let cal = context.calendar
        let horizonStart = context.planningHorizon.start
        for i in genes.indices {
            guard context.rng.bool(probability: rate) else { continue }

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
            let strategy = context.rng.int(in: 0...3)

            switch strategy {
            case 0:
                // Small time shift: +-30 min
                let shift = context.rng.double(in: -1800.0...1800.0)
                let newStart = max(genes[i].startTime.addingTimeInterval(shift), floor)
                genes[i] = genes[i].withStartTime(
                    clampToWorkingHours(newStart, duration: genes[i].duration, workingHours: context.workingHours, calendar: cal, floor: floor)
                )
            case 1:
                // Move to different day within horizon
                let mutStartDay = cal.startOfDay(for: horizonStart)
                let mutLastDay = cal.startOfDay(for: context.planningHorizon.end.addingTimeInterval(-1))
                let daysInHorizon = max(1, (cal.dateComponents([.day], from: mutStartDay, to: mutLastDay).day ?? 0) + 1)
                guard daysInHorizon > 0 else { break }
                let dayOffset = context.rng.int(in: 0..<daysInHorizon)
                let newDay = cal.date(byAdding: .day, value: dayOffset, to: horizonStart)!
                let hour: Int
                if let preferred = event?.preferredHourRange, !preferred.isEmpty {
                    hour = context.rng.int(in: preferred)
                } else {
                    hour = context.rng.int(in: context.workingHours)
                }
                let rawStart = max(cal.date(bySettingHour: hour, minute: context.rng.int(in: 0...3) * 15, second: 0, of: newDay)!, floor)
                genes[i] = genes[i].withStartTime(
                    clampToWorkingHours(rawStart, duration: genes[i].duration, workingHours: context.workingHours, calendar: cal, floor: floor)
                )
            case 2:
                // Snap to nearest half-hour
                let timeInterval = genes[i].startTime.timeIntervalSinceReferenceDate
                let snapped = max(Date(timeIntervalSinceReferenceDate: (timeInterval / 1800).rounded() * 1800), floor)
                genes[i] = genes[i].withStartTime(
                    clampToWorkingHours(snapped, duration: genes[i].duration, workingHours: context.workingHours, calendar: cal, floor: floor)
                )
            case 3:
                // Guided mutation: find nearest free gap and place there
                let occupied = collectOccupiedIntervals(excluding: i, context: context)
                if let freeStart = findNearestFreeSlot(
                    near: genes[i].startTime,
                    duration: genes[i].duration,
                    occupied: occupied,
                    workingHours: context.workingHours,
                    horizon: context.planningHorizon,
                    calendar: cal,
                    floor: floor
                ) {
                    genes[i] = genes[i].withStartTime(freeStart)
                }
            default:
                break
            }
        }
        mutatedGeneIndices = changed.isEmpty ? nil : changed
    }

    // MARK: - Guided Mutation Helpers

    /// Collect all occupied time intervals in the schedule, excluding gene at `excludeIndex`.
    private func collectOccupiedIntervals(excluding excludeIndex: Int, context: OptimizerContext) -> [(start: Date, end: Date)] {
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
    private func findNearestFreeSlot(
        near: Date,
        duration: TimeInterval,
        occupied: [(start: Date, end: Date)],
        workingHours: ClosedRange<Int>,
        horizon: DateInterval,
        calendar: Calendar,
        floor: Date
    ) -> Date? {
        // Search forward and backward from current position, try gap between each pair
        var candidates: [(start: Date, distance: TimeInterval)] = []

        // Build sorted occupied list within horizon
        let sorted = occupied.filter { $0.end > horizon.start && $0.start < horizon.end }

        // Scan gaps between occupied intervals
        var prevEnd = horizon.start
        for occ in sorted {
            let gapStart = max(prevEnd, floor)
            let gapEnd = occ.start
            if gapEnd.timeIntervalSince(gapStart) >= duration {
                let clamped = clampToWorkingHours(gapStart, duration: duration, workingHours: workingHours, calendar: calendar, floor: floor)
                if clamped.addingTimeInterval(duration) <= gapEnd {
                    candidates.append((clamped, abs(clamped.timeIntervalSince(near))))
                }
            }
            prevEnd = max(prevEnd, occ.end)
        }
        // Gap after last occupied
        let finalGapStart = max(prevEnd, floor)
        if horizon.end.timeIntervalSince(finalGapStart) >= duration {
            let clamped = clampToWorkingHours(finalGapStart, duration: duration, workingHours: workingHours, calendar: calendar, floor: floor)
            if clamped.addingTimeInterval(duration) <= horizon.end {
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
    mutating func repair(context: OptimizerContext) {
        let cal = context.calendar
        let horizonStart = context.planningHorizon.start

        // Pass 1: Clamp to working hours and planning horizon
        for i in genes.indices where genes[i].isIncluded {
            let event = context.movableEvents.first { $0.id == genes[i].eventId }
            let earliest = event?.earliestStart
            let floor = [horizonStart, earliest].compactMap { $0 }.max() ?? horizonStart

            genes[i] = genes[i].withStartTime(
                clampToWorkingHours(genes[i].startTime, duration: genes[i].duration, workingHours: context.workingHours, calendar: cal, floor: floor)
            )
        }

        // Pass 2: Resolve overlaps greedily (higher-priority genes keep their slots)
        // Sort by priority descending, then by start time
        let sortedIndices = genes.indices
            .filter { genes[$0].isIncluded }
            .sorted { genes[$0].priority > genes[$1].priority }

        var occupied: [(start: Date, end: Date)] = context.fixedEvents.map {
            ($0.startDate, $0.endDate)
        }
        occupied.sort { $0.start < $1.start }

        for idx in sortedIndices {
            let gene = genes[idx]
            let hasOverlap = occupied.contains { occ in
                gene.startTime < occ.end && gene.endTime > occ.start
            }

            if hasOverlap {
                let event = context.movableEvents.first { $0.id == gene.eventId }
                let earliest = event?.earliestStart
                let floor = [horizonStart, earliest].compactMap { $0 }.max() ?? horizonStart

                if let freeStart = findNearestFreeSlot(
                    near: gene.startTime,
                    duration: gene.duration,
                    occupied: occupied,
                    workingHours: context.workingHours,
                    horizon: context.planningHorizon,
                    calendar: cal,
                    floor: floor
                ) {
                    genes[idx] = gene.withStartTime(freeStart)
                }
            }

            occupied.append((genes[idx].startTime, genes[idx].endTime))
            occupied.sort { $0.start < $1.start }
        }

        needsEvaluation = true
    }

    // MARK: - Genotypic Distance

    /// Normalized distance between two schedule chromosomes in [0, 1].
    /// Combines time displacement and inclusion differences across genes.
    ///
    /// - Complexity: O(n) — other.genes is indexed by eventId once. Previously
    ///   O(n²) due to repeated `.first(where:)` lookups, which was a hot path
    ///   because `genotypicDiversity` and crowding both call it every generation.
    func distance(to other: ScheduleChromosome) -> Double {
        guard !genes.isEmpty else { return 0 }

        // Fast path: identical gene order (common when both descend from same parent).
        // Avoid building the index dictionary when we can align by position.
        let alignedByIndex = genes.count == other.genes.count
            && zip(genes, other.genes).allSatisfy { $0.eventId == $1.eventId }

        var totalDiff = 0.0
        var count = 0

        if alignedByIndex {
            for i in genes.indices {
                totalDiff += pairDistance(genes[i], other.genes[i], &count)
            }
        } else {
            let otherById: [String: ScheduleGene] = Dictionary(
                other.genes.map { ($0.eventId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for geneA in genes {
                guard let geneB = otherById[geneA.eventId] else {
                    totalDiff += 1.0
                    count += 1
                    continue
                }
                totalDiff += pairDistance(geneA, geneB, &count)
            }
        }

        return count > 0 ? totalDiff / Double(count) : 0
    }

    /// Per-gene distance contribution. Mutates `count` to keep the two paths aligned.
    @inline(__always)
    private func pairDistance(_ a: ScheduleGene, _ b: ScheduleGene, _ count: inout Int) -> Double {
        count += 1
        // Inclusion mismatch = full difference
        if a.isIncluded != b.isIncluded { return 1.0 }
        // Both excluded = identical
        if !a.isIncluded { return 0.0 }
        // Time difference normalized by 9h working day
        let timeDiff = abs(a.startTime.timeIntervalSince(b.startTime))
        return min(1.0, timeDiff / (9 * 3600))
    }

    // MARK: - Helpers

    private static func randomStartTime(
        for event: OptimizableEvent,
        in horizon: DateInterval,
        workingHours: ClosedRange<Int>,
        calendar: Calendar,
        rng: GARandom
    ) -> Date {
        // Count distinct calendar days spanned (not whole 24h periods) so
        // the GA can reach every day in the horizon, even when the start is
        // mid-afternoon and the horizon overflows into the next day.
        let horizonStartDay = calendar.startOfDay(for: horizon.start)
        let horizonLastDay = calendar.startOfDay(for: horizon.end.addingTimeInterval(-1))
        let daysInHorizon = max(1, (calendar.dateComponents([.day], from: horizonStartDay, to: horizonLastDay).day ?? 0) + 1)
        let dayOffset = rng.int(in: 0..<daysInHorizon)
        let day = calendar.date(byAdding: .day, value: dayOffset, to: horizon.start)!

        let hourRange = event.preferredHourRange ?? workingHours
        let maxStartHour = max(hourRange.lowerBound, hourRange.upperBound - Int(event.duration / 3600))
        let hour = rng.int(in: hourRange.lowerBound...max(hourRange.lowerBound, maxStartHour))
        let minute = rng.int(in: 0...3) * 15

        var result = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            ?? horizon.start

        // Respect earliestStart — don't place before it
        if let earliest = event.earliestStart, result < earliest {
            result = earliest
        }

        // Never place before the planning horizon start (e.g. in the past)
        if result < horizon.start {
            result = horizon.start
        }

        return result
    }
}

// MARK: - Free functions

func clampToWorkingHours(
    _ date: Date,
    duration: TimeInterval,
    workingHours: ClosedRange<Int>,
    calendar: Calendar,
    floor: Date? = nil
) -> Date {
    let day = calendar.startOfDay(for: date)
    guard let workStart = calendar.date(bySettingHour: workingHours.lowerBound, minute: 0, second: 0, of: day),
          let workEnd = calendar.date(bySettingHour: workingHours.upperBound, minute: 0, second: 0, of: day) else {
        return date
    }

    // Clamp start so event doesn't begin before working hours or floor
    let lowerBound = if let floor { max(workStart, floor) } else { workStart }
    var clamped = max(date, lowerBound)

    // Clamp start so event doesn't end after working hours
    let latestStart = workEnd.addingTimeInterval(-duration)
    if latestStart >= lowerBound {
        clamped = min(clamped, latestStart)
    } else {
        // Duration exceeds available window — start at lower bound
        clamped = lowerBound
    }

    return clamped
}
