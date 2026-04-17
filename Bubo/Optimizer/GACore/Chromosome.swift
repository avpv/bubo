import Foundation
import simd

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

    /// Hook that the GA calls after every offspring's fitness is known so
    /// chromosome-local mutation operator state can self-adapt on the
    /// observed outcome. `improved` is true when the offspring's fitness
    /// beat the baseline used for bandit reward (max parent fitness).
    /// Default no-op; conforming types opt in by overriding.
    ///
    /// Used by `ScheduleChromosome` to update the CMA-ES-lite per-gene
    /// sigma vector via the 1/5 success rule. Called once per offspring
    /// per generation, so the cost is amortized by the mutation itself.
    mutating func adaptOperatorState(improved: Bool)
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

    /// Default: no adaptive operator state. Permutation genomes
    /// (PomodoroSequenceChromosome) rely on this.
    mutating func adaptOperatorState(improved: Bool) {}
}

// MARK: - Schedule Chromosome

/// A chromosome representing a complete schedule assignment.
/// Each gene maps one movable event to a specific time slot.
struct ScheduleChromosome: Chromosome, AdaptiveMutationChromosome, Sendable {
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

    /// The operator picked by the `MutationBandit` on the last `mutate()` call,
    /// if any. The GA loop reads this post-evaluation to attribute the fitness
    /// delta back to the operator, closing the UCB1 feedback loop. `nil` when
    /// the bandit wasn't wired or when mutate() was skipped (no rate hit any
    /// gene). Does not participate in equality/hashing.
    var lastMutationOperator: MutationOperator?

    /// Self-adaptive mutation rate encoded directly in the genome. When > 0
    /// it overrides the rate the GA would otherwise pass to `mutate(rate:)`,
    /// and is itself perturbed on every mutation — so a chromosome descended
    /// from individuals that benefited from higher rates will keep mutating
    /// aggressively, and vice versa. 0 = disabled (the GA's externally-set
    /// rate wins, preserving pre-existing behaviour).
    var selfAdaptiveMutationRate: Double = 0

    /// Per-gene standard deviation used by the CMA-ES-lite Gaussian shift
    /// operator (replacing the fixed ±30 min uniform shift from Phase 1).
    /// Each entry is in seconds and evolves via the 1/5 success rule:
    /// after a mutation on gene `i`, the GA multiplies `perGeneSigma[i]`
    /// by 1.2 if the resulting chromosome improved on its parent, else
    /// 0.85. This lets the step size per gene shrink in regions where
    /// fine-tuning works and grow where we need bigger jumps.
    ///
    /// `nil` on freshly-constructed chromosomes — the mutation operator
    /// lazily initializes every entry to `CMAESConfig.initialSigmaSeconds`.
    /// Crossover inherits the per-parent mean so well-adapted step sizes
    /// propagate through the population.
    var perGeneSigma: [TimeInterval]?

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
            Self.makeChild(genes: child1Genes, parents: (self, other), rng: context.rng),
            Self.makeChild(genes: child2Genes, parents: (other, self), rng: context.rng)
        )
    }

    /// Build a crossover child. Factored out so every crossover strategy
    /// (singlePoint, twoPoint, uniform, dayBlock, linkageTree) propagates
    /// self-adaptive parameters the same way: child inherits each parent's
    /// mutation-rate and CMA-ES-lite sigma vector by arithmetic mean with
    /// small jitter. Jitter keeps the rate- and sigma-genes under
    /// selection pressure; without it the whole population would converge
    /// on the mean almost immediately.
    static func makeChild(
        genes: [ScheduleGene],
        parents: (ScheduleChromosome, ScheduleChromosome),
        rng: GARandom
    ) -> ScheduleChromosome {
        var child = ScheduleChromosome(genes: genes, needsEvaluation: true)

        // Self-adaptive mutation rate (Phase 1)
        let p1 = parents.0.selfAdaptiveMutationRate
        let p2 = parents.1.selfAdaptiveMutationRate
        if p1 > 0 || p2 > 0 {
            let mean = (p1 + p2) / (p1 > 0 && p2 > 0 ? 2.0 : 1.0)
            let jitter = rng.double(in: -0.05...0.05) * mean
            child.selfAdaptiveMutationRate = min(0.8, max(0.01, mean + jitter))
        }

        // CMA-ES-lite per-gene sigma: align by gene index length, take
        // parent-wise mean where both are present, fall back to the single
        // available parent, and leave nil when neither parent has been
        // evaluated yet (lazy-init will seed on first mutation).
        let s1 = parents.0.perGeneSigma
        let s2 = parents.1.perGeneSigma
        if s1 != nil || s2 != nil {
            var sigmas = [TimeInterval](repeating: CMAESConfig.initialSigmaSeconds, count: genes.count)
            for i in 0..<genes.count {
                let v1 = s1.flatMap { i < $0.count ? $0[i] : nil }
                let v2 = s2.flatMap { i < $0.count ? $0[i] : nil }
                let base: TimeInterval
                switch (v1, v2) {
                case let (a?, b?): base = (a + b) / 2
                case let (a?, nil): base = a
                case let (nil, b?): base = b
                default: base = CMAESConfig.initialSigmaSeconds
                }
                // Log-uniform jitter so the ratio stays balanced (avoids
                // drift toward either floor when arithmetic jitter is
                // repeatedly clipped).
                let logJitter = rng.double(in: -0.1...0.1)
                let jittered = base * exp(logJitter)
                sigmas[i] = min(CMAESConfig.maxSigmaSeconds,
                                max(CMAESConfig.minSigmaSeconds, jittered))
            }
            child.perGeneSigma = sigmas
        }

        return child
    }

    // MARK: - CMA-ES-lite Sigma Adaptation

    /// Ensure `perGeneSigma` is populated with the initial sigma. Called
    /// lazily by the Gaussian shift operator so freshly-constructed
    /// chromosomes pay nothing until they actually mutate.
    mutating func lazyInitSigmas() {
        if perGeneSigma == nil || perGeneSigma?.count != genes.count {
            perGeneSigma = [TimeInterval](
                repeating: CMAESConfig.initialSigmaSeconds,
                count: genes.count
            )
        }
    }

    /// Update the per-gene sigma vector via the 1/5 success rule after a
    /// mutation's outcome is known. Genes that were actually mutated
    /// (captured in `mutatedGeneIndices`) get sigma grown on success
    /// (`multiplier = 1.2`) and shrunk on failure (`0.85`); unmutated
    /// genes are untouched. Clamped to [minSigma, maxSigma].
    ///
    /// Called from the GA loop once offspring are evaluated — it needs
    /// the comparison against the parent, which the mutate step can't
    /// see.
    mutating func adaptSigmas(improved: Bool) {
        guard let mutated = mutatedGeneIndices, !mutated.isEmpty else { return }
        lazyInitSigmas()
        guard var sigmas = perGeneSigma else { return }
        let multiplier = improved
            ? CMAESConfig.successMultiplier
            : CMAESConfig.failureMultiplier
        for idx in mutated where idx < sigmas.count {
            let next = sigmas[idx] * multiplier
            sigmas[idx] = min(CMAESConfig.maxSigmaSeconds,
                              max(CMAESConfig.minSigmaSeconds, next))
        }
        perGeneSigma = sigmas
    }

    /// Adopt the generic `adaptOperatorState` hook from `Chromosome` so
    /// the GA loop can drive sigma adaptation without a type-specific
    /// cast. Forwards to `adaptSigmas(improved:)`.
    mutating func adaptOperatorState(improved: Bool) {
        adaptSigmas(improved: improved)
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

        // If a bandit is wired, choose one operator for this entire call and
        // use it for every gene that gets selected. The feedback loop works
        // at call granularity (pre vs. post fitness), so per-gene operator
        // variation would make the reward signal harder to attribute. Without
        // a bandit, we keep the per-gene uniform-random behaviour so existing
        // runs produce the same distribution of mutations.
        let bandedOperator: MutationOperator? = context.mutationBandit?.select(rng: context.rng)
        lastMutationOperator = bandedOperator

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
            let strategy: Int
            if let op = bandedOperator {
                strategy = op.rawValue
            } else {
                strategy = context.rng.int(in: 0...3)
            }

            switch strategy {
            case 0:
                // CMA-ES-lite Gaussian shift. Replaces the uniform ±30-min
                // shift with N(0, σ_i) sampling, where σ_i is a per-gene
                // step size adapted via the 1/5 success rule (see
                // `adaptSigmas(improvedForGenes:)`). Gives the GA a smooth
                // knob between fine-tuning (small σ) and local search
                // (large σ) without a config change.
                lazyInitSigmas()
                let sigma = perGeneSigma?[i] ?? CMAESConfig.initialSigmaSeconds
                let delta = context.rng.gaussian(mean: 0.0, stdDev: sigma)
                let newStart = max(genes[i].startTime.addingTimeInterval(delta), floor)
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
    /// 3. Enforce `dependsOn` ordering: a gene may only start after every one
    ///    of its (included) prerequisites has finished.
    mutating func repair(context: OptimizerContext) {
        let cal = context.calendar
        let horizonStart = context.planningHorizon.start

        // Pass 0: AC-3-lite dependency-chain feasibility pruning.
        //
        // Propagate the dependency graph to derive each gene's true
        // earliest-start (max over own earliestStart and every
        // transitive prerequisite's endTime). When that floor plus the
        // gene's duration exceeds its deadline, the gene is infeasible
        // and placing it will only trigger hard-constraint penalties
        // downstream. For *droppable* genes we flip `isIncluded = false`
        // instead, which (a) lets the GA honour the drop permission
        // rather than fighting it through repeated mutations, and (b)
        // removes the infeasible gene from later overlap resolution so
        // it doesn't displace feasible neighbours. Non-droppable genes
        // stay flagged (they will still score poorly via the deadline
        // objective, which the GA uses for gradient information).
        applyDependencyFeasibilityPruning(context: context)

        // Pass 1: Clamp to working hours and planning horizon
        for i in genes.indices where genes[i].isIncluded {
            let event = context.movableEvents.first { $0.id == genes[i].eventId }
            let earliest = event?.earliestStart
            let floor = [horizonStart, earliest].compactMap { $0 }.max() ?? horizonStart

            genes[i] = genes[i].withStartTime(
                clampToWorkingHours(genes[i].startTime, duration: genes[i].duration, workingHours: context.workingHours, calendar: cal, floor: floor)
            )
        }

        // Pass 2: Resolve overlaps. We visit genes in topological order
        // (prerequisites before dependents) so a dependent's overlap check
        // observes already-placed prerequisites; ties broken by priority
        // descending so high-priority tasks still keep their slots when no
        // dependency edge dictates order. Cycles degrade gracefully: nodes
        // left in the work list after Kahn's algorithm finishes get appended
        // in priority order, preserving the pre-topological behaviour.
        let sortedIndices = topoOrderedIndices(context: context)

        var occupied: [(start: Date, end: Date)] = context.fixedEvents.map {
            ($0.startDate, $0.endDate)
        }
        occupied.sort { $0.start < $1.start }

        for idx in sortedIndices {
            let gene = genes[idx]
            let event = context.movableEvents.first { $0.id == gene.eventId }
            let earliest = event?.earliestStart
            var floor = [horizonStart, earliest].compactMap { $0 }.max() ?? horizonStart

            // Dependency floor: this gene may not start before any of its
            // included prerequisites has finished. Because we iterate in
            // topological order, every prerequisite has already been placed
            // in its final slot for this repair pass.
            if let event, !event.dependsOn.isEmpty {
                for depId in event.dependsOn {
                    if let depGene = genes.first(where: { $0.eventId == depId && $0.isIncluded }) {
                        floor = max(floor, depGene.endTime)
                    }
                }
            }

            // If the current slot is either before the dependency floor or
            // overlaps an occupied interval, relocate to the nearest valid gap.
            let beforeFloor = gene.startTime < floor
            let hasOverlap = occupied.contains { occ in
                gene.startTime < occ.end && gene.endTime > occ.start
            }

            if beforeFloor || hasOverlap {
                if let freeStart = findNearestFreeSlot(
                    near: max(gene.startTime, floor),
                    duration: gene.duration,
                    occupied: occupied,
                    workingHours: context.workingHours,
                    horizon: context.planningHorizon,
                    calendar: cal,
                    floor: floor
                ) {
                    genes[idx] = gene.withStartTime(freeStart)
                } else if beforeFloor {
                    // No gap fits but dependency floor was violated — at least
                    // honour the floor; this may still overlap, which leaves
                    // the ConstraintEngine to penalise rather than failing
                    // the whole repair silently.
                    genes[idx] = gene.withStartTime(
                        clampToWorkingHours(floor, duration: gene.duration,
                                            workingHours: context.workingHours,
                                            calendar: cal, floor: floor)
                    )
                }
            }

            occupied.append((genes[idx].startTime, genes[idx].endTime))
            occupied.sort { $0.start < $1.start }
        }

        needsEvaluation = true
    }

    /// AC-3-lite dependency feasibility pruning.
    ///
    /// For every included gene, derive the tightest possible earliest-
    /// start time by transitively closing over `dependsOn`:
    ///   floor_i = max(event_i.earliestStart, floor_j + duration_j for j in deps(i))
    /// We iterate to a fixed point (bounded by number of genes) — any
    /// residual change after that implies a cycle, which we tolerate by
    /// leaving affected genes as-is (their repair still runs later).
    /// When `floor_i + duration_i > event_i.deadline`, the gene is
    /// provably infeasible and we drop it when allowed (isDroppable).
    /// Non-droppable infeasible genes stay flagged; the deadline
    /// objective will carry the gradient.
    private mutating func applyDependencyFeasibilityPruning(context: OptimizerContext) {
        let horizonStart = context.planningHorizon.start
        let eventById: [String: OptimizableEvent] = Dictionary(
            uniqueKeysWithValues: context.movableEvents.map { ($0.id, $0) }
        )

        // Seed floors from events' own earliestStart and the horizon.
        var floors: [String: Date] = [:]
        for gene in genes where gene.isIncluded {
            let event = eventById[gene.eventId]
            let base = [horizonStart, event?.earliestStart].compactMap { $0 }.max() ?? horizonStart
            floors[gene.eventId] = base
        }

        // Fixed-event prerequisites are immovable, so their end times are
        // a stable floor source. Include them too — otherwise a gene
        // depending on a fixed event wouldn't see the correct floor
        // derivation.
        var fixedEndById: [String: Date] = [:]
        for event in context.fixedEvents {
            fixedEndById[event.id] = event.endDate
        }

        // Propagate floors to a fixed point. `geneCount + 1` iterations
        // is enough to resolve any acyclic dependency chain; a cycle
        // would never converge so the bound also caps wasted work.
        let maxIterations = genes.count + 1
        var changed = true
        var iter = 0
        while changed && iter < maxIterations {
            changed = false
            iter += 1
            for gene in genes where gene.isIncluded {
                guard let event = eventById[gene.eventId] else { continue }
                var floor = floors[gene.eventId] ?? horizonStart
                for depId in event.dependsOn {
                    // Prerequisite end time = dep's floor + dep's duration
                    // (for included movable genes), or fixed event's end.
                    if let depFloor = floors[depId],
                       let depGene = genes.first(where: { $0.eventId == depId && $0.isIncluded }) {
                        let depEnd = depFloor.addingTimeInterval(depGene.duration)
                        if depEnd > floor { floor = depEnd }
                    } else if let fixedEnd = fixedEndById[depId] {
                        if fixedEnd > floor { floor = fixedEnd }
                    }
                }
                if let current = floors[gene.eventId], floor > current {
                    floors[gene.eventId] = floor
                    changed = true
                }
            }
        }

        // Feasibility check + droppable pruning.
        for i in genes.indices where genes[i].isIncluded {
            guard let event = eventById[genes[i].eventId] else { continue }
            let floor = floors[genes[i].eventId] ?? horizonStart
            if let deadline = event.deadline,
               floor.addingTimeInterval(genes[i].duration) > deadline,
               event.isDroppable {
                genes[i].isIncluded = false
            }
        }
    }

    /// Kahn's algorithm on the `dependsOn` graph among included genes, with
    /// ties broken by priority descending. Returns every included gene's
    /// index exactly once: prerequisites first, then dependents. Dependencies
    /// on excluded/absent genes are ignored (they can't influence timing).
    /// Cycles leave some indices unvisited; those are appended at the end in
    /// priority order so repair behaviour on malformed graphs matches the
    /// pre-topological version.
    private func topoOrderedIndices(context: OptimizerContext) -> [Int] {
        let includedIndices = genes.indices.filter { genes[$0].isIncluded }
        guard !includedIndices.isEmpty else { return [] }

        // Map eventId → gene index for O(1) lookup during edge construction.
        var indexByEventId: [String: Int] = [:]
        indexByEventId.reserveCapacity(includedIndices.count)
        for i in includedIndices { indexByEventId[genes[i].eventId] = i }

        // Pre-compute inDegrees and adjacency (dependency → dependent edges).
        var inDegree: [Int: Int] = [:]
        var adjacency: [Int: [Int]] = [:]
        for i in includedIndices { inDegree[i] = 0 }

        let eventById: [String: OptimizableEvent] = Dictionary(
            uniqueKeysWithValues: context.movableEvents.map { ($0.id, $0) }
        )

        for i in includedIndices {
            guard let event = eventById[genes[i].eventId] else { continue }
            for depId in event.dependsOn {
                // Only count dependencies on included genes present in this
                // chromosome. Excluded or missing prerequisites don't impose
                // a scheduling order.
                if let depIdx = indexByEventId[depId] {
                    adjacency[depIdx, default: []].append(i)
                    inDegree[i, default: 0] += 1
                }
            }
        }

        // Kahn's algorithm with a priority-ordered ready queue. A plain queue
        // would be topologically valid but arbitrary on ties; using priority
        // preserves the "important gene first" behaviour of the previous
        // overlap-resolution pass.
        var ready = includedIndices
            .filter { (inDegree[$0] ?? 0) == 0 }
            .sorted { genes[$0].priority > genes[$1].priority }
        var result: [Int] = []
        result.reserveCapacity(includedIndices.count)

        while !ready.isEmpty {
            // Always pop the highest-priority ready node. Linear scan is fine
            // here because `ready` stays small relative to population sizes.
            let head = ready.removeFirst()
            result.append(head)
            for dependent in adjacency[head] ?? [] {
                let next = (inDegree[dependent] ?? 0) - 1
                inDegree[dependent] = next
                if next == 0 {
                    // Insert keeping ready sorted by priority descending.
                    let insertAt = ready.firstIndex { genes[$0].priority < genes[dependent].priority } ?? ready.count
                    ready.insert(dependent, at: insertAt)
                }
            }
        }

        // Any indices still with inDegree > 0 are part of a cycle. Append them
        // in priority order so repair still has something to iterate over —
        // cycles are a data-integrity bug but shouldn't crash the optimizer.
        let visited = Set(result)
        let leftovers = includedIndices
            .filter { !visited.contains($0) }
            .sorted { genes[$0].priority > genes[$1].priority }
        result.append(contentsOf: leftovers)
        return result
    }

    // MARK: - Genotypic Distance

    /// Normalized distance between two schedule chromosomes in [0, 1].
    /// Combines time displacement and inclusion differences across genes.
    ///
    /// - Complexity: O(n) — other.genes is indexed by eventId once. Previously
    ///   O(n²) due to repeated `.first(where:)` lookups, which was a hot path
    ///   because `genotypicDiversity` and crowding both call it every generation.
    /// - SIMD: the aligned-by-index path (both parents descend from the same
    ///   lineage — the common case in steady-state GA) processes four gene
    ///   pairs at a time using `SIMD4<Double>` for the time-difference lanes.
    ///   Branching on inclusion stays scalar because the three-way logic
    ///   (both-excluded / mismatched / both-included) doesn't vectorize
    ///   cleanly, but the time-diff lanes dominate the arithmetic cost.
    func distance(to other: ScheduleChromosome) -> Double {
        guard !genes.isEmpty else { return 0 }

        // Fast path: identical gene order (common when both descend from same parent).
        // Avoid building the index dictionary when we can align by position.
        let alignedByIndex = genes.count == other.genes.count
            && zip(genes, other.genes).allSatisfy { $0.eventId == $1.eventId }

        if alignedByIndex {
            return simdAlignedDistance(to: other)
        }

        // Slow path: genes don't align by index (pre-crossover parents, or
        // chromosomes from different lineages). Use dictionary lookup.
        var totalDiff = 0.0
        var count = 0
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
        return count > 0 ? totalDiff / Double(count) : 0
    }

    /// Aligned-index distance computed four lanes at a time.
    ///
    /// For each batch of 4 gene pairs, the time differences are computed in a
    /// single `SIMD4<Double>` subtraction, absolute-valued, and normalized
    /// against the 9h reference — three instructions instead of twelve. The
    /// inclusion logic remains scalar; it's a cheap branch-predictor-friendly
    /// pattern because in most generations the vast majority of genes keep
    /// their inclusion flag.
    @inline(__always)
    private func simdAlignedDistance(to other: ScheduleChromosome) -> Double {
        let n = genes.count
        let normalize = 9.0 * 3600.0
        var totalDiff = 0.0
        var count = 0

        var i = 0
        while i + 4 <= n {
            // Gather four time differences in one SIMD op. We load
            // timeIntervalSinceReferenceDate directly (Double) rather than
            // going through timeIntervalSince() which would be an extra
            // subtract per lane.
            let aTimes = SIMD4<Double>(
                genes[i].startTime.timeIntervalSinceReferenceDate,
                genes[i + 1].startTime.timeIntervalSinceReferenceDate,
                genes[i + 2].startTime.timeIntervalSinceReferenceDate,
                genes[i + 3].startTime.timeIntervalSinceReferenceDate
            )
            let bTimes = SIMD4<Double>(
                other.genes[i].startTime.timeIntervalSinceReferenceDate,
                other.genes[i + 1].startTime.timeIntervalSinceReferenceDate,
                other.genes[i + 2].startTime.timeIntervalSinceReferenceDate,
                other.genes[i + 3].startTime.timeIntervalSinceReferenceDate
            )
            let rawDelta = aTimes - bTimes
            // `abs()` returns abs value per-lane. Divide by normalize to
            // put every lane in [0, ∞); the final min(1, ·) clamps the tail.
            let normalized = abs(rawDelta) / SIMD4(repeating: normalize)
            let clamped = normalized.clamped(
                lowerBound: SIMD4<Double>.zero,
                upperBound: SIMD4(repeating: 1.0)
            )

            for lane in 0..<4 {
                let a = genes[i + lane]
                let b = other.genes[i + lane]
                count += 1
                if a.isIncluded != b.isIncluded {
                    totalDiff += 1.0
                } else if !a.isIncluded {
                    // Both excluded — distance contribution is 0, no-op.
                } else {
                    totalDiff += clamped[lane]
                }
            }
            i += 4
        }

        // Scalar remainder for tail < 4.
        while i < n {
            totalDiff += pairDistance(genes[i], other.genes[i], &count)
            i += 1
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
