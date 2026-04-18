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

    /// Per-component breakdown for `ComponentPartitionedObjective`
    /// instances. Outer key = objective name; inner key = component
    /// index from `ScheduleConflictGraph.componentOf`. Components that
    /// don't contain any mutated gene keep their cached score across
    /// delta evaluations.
    var perComponentObjectiveCache: [String: [Int: Double]]?

    /// For each gene position, the day it sat on the last time this chromosome
    /// was fully evaluated. Used to spot "a gene moved from day X to day Y"
    /// and mark both X and Y as dirty, so per-day delta evaluation doesn't
    /// leave stale scores on abandoned days. `nil` means "no prior evaluation"
    /// and forces a full pass.
    var geneDaysSnapshot: [Date]?

    /// Indices of genes that were modified since last evaluation.
    /// Used by delta evaluation to skip recomputing unaffected local objectives.
    var mutatedGeneIndices: IndexSet?

    /// The operator picked by the `MutationBandit` on the last `mutate()`
    /// call. The GA loop reads this post-evaluation to attribute the
    /// fitness delta back to the operator, closing the LinUCB feedback
    /// loop. `nil` only on freshly-constructed chromosomes whose
    /// `mutate()` has not yet run. Does not participate in
    /// equality/hashing.
    var lastMutationOperator: MutationOperator?

    /// The destroy strategy used on the most recent LNS call. `nil` when
    /// `lastMutationOperator != .lnsDay`. The GA loop reads this to feed
    /// `LNSStrategyBandit` the same fitness delta that went to the
    /// operator-level bandit, so strategy weights adapt with experience.
    var lastDestroyStrategy: LNSDestroyStrategy?

    /// Self-adaptive mutation rate encoded directly in the genome. When > 0
    /// it overrides the rate the GA would otherwise pass to `mutate(rate:)`,
    /// and is itself perturbed on every mutation — so a chromosome descended
    /// from individuals that benefited from higher rates will keep mutating
    /// aggressively, and vice versa. 0 = disabled (the GA's externally-set
    /// rate wins, preserving pre-existing behaviour).
    var selfAdaptiveMutationRate: Double = 0

    /// Cached 16-dim feature vector for surrogate / QD consumers.
    /// Populated lazily on first extraction and invalidated on any
    /// mutation (`mutate`) or repair that changes gene placement.
    /// Surrogate screening hits this cache for every offspring
    /// evaluation — eliminating the re-aggregation pass saves ~10-30µs
    /// per offspring, multiplied by generations × populationSize this
    /// is a meaningful slice of the per-run cost.
    var cachedFeatures: ContiguousArray<Double>?

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
    private static func findLastFreeSlot(
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
    fileprivate struct OccupiedInterval {
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
    private static func enumerateFeasibleSlots(
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
                    let d = Double(hour - preferences.peakEnergyHour)
                    energyLevel = exp(-d * d * 0.02)
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
    /// (singlePoint, twoPoint, uniform, dayBlock) propagates self-adaptive
    /// parameters the same way: child.rate = mean(parents) jittered by ±5%.
    /// Jitter keeps the rate-gene under selection pressure; without it the
    /// whole population would converge on the mean almost immediately.
    static func makeChild(
        genes: [ScheduleGene],
        parents: (ScheduleChromosome, ScheduleChromosome),
        rng: GARandom
    ) -> ScheduleChromosome {
        var child = ScheduleChromosome(genes: genes, needsEvaluation: true)
        let p1 = parents.0.selfAdaptiveMutationRate
        let p2 = parents.1.selfAdaptiveMutationRate
        if p1 > 0 || p2 > 0 {
            let mean = (p1 + p2) / (p1 > 0 && p2 > 0 ? 2.0 : 1.0)
            let jitter = rng.double(in: -0.05...0.05) * mean
            child.selfAdaptiveMutationRate = min(0.8, max(0.01, mean + jitter))
        }
        return child
    }

    /// Strategy-aware crossover that delegates to the Crossover enum.
    func crossover(with other: ScheduleChromosome, strategy: CrossoverStrategy, context: OptimizerContext) -> (ScheduleChromosome, ScheduleChromosome) {
        Crossover.perform(self, other, strategy: strategy, context: context)
    }

    // MARK: - Mutation

    mutating func mutate(rate: Double, context: OptimizerContext) {
        needsEvaluation = true
        // Feature cache is a function of gene placement; mutation may
        // change placement, invalidate eagerly. Surrogate screen will
        // recompute on next access.
        cachedFeatures = nil
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
            mutatedGeneIndices = applyLNS(rate: effectiveRate, context: context)
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
                // Small time shift: +-30 min
                let shift = context.rng.double(in: -1800.0...1800.0)
                let newStart = max(genes[i].startTime.addingTimeInterval(shift), floor)
                genes[i] = genes[i].withStartTime(
                    clampToWorkingHours(newStart, duration: genes[i].duration, workingHours: context.workingHours, calendar: cal, floor: floor)
                )
            case 1:
                // Move to different day within horizon.
                //
                // Constraint-aware: restrict day selection to days
                // that are at or after `floor` (which already folds
                // `earliestStart` and, via repair's dependency pass,
                // the earliest day any included prerequisite could
                // finish). Random days earlier than that would be
                // immediately reshuffled by the next repair pass,
                // costing a wasted fitness evaluation per mutation.
                let mutStartDay = cal.startOfDay(for: horizonStart)
                let mutLastDay = cal.startOfDay(for: context.planningHorizon.end.addingTimeInterval(-1))
                let daysInHorizon = max(1, (cal.dateComponents([.day], from: mutStartDay, to: mutLastDay).day ?? 0) + 1)
                guard daysInHorizon > 0 else { break }

                // Earliest eligible day: max of horizon start and the
                // day holding `floor`. Also advance past `dependsOn`
                // predecessors placed on this chromosome.
                var earliestDay = cal.startOfDay(for: floor)
                if let event, !event.dependsOn.isEmpty {
                    for depId in event.dependsOn {
                        if let depGene = genes.first(where: { $0.eventId == depId && $0.isIncluded }) {
                            let depDay = cal.startOfDay(for: depGene.endTime)
                            if depDay > earliestDay { earliestDay = depDay }
                        }
                    }
                }
                let startOffset = max(
                    0,
                    cal.dateComponents([.day], from: mutStartDay, to: earliestDay).day ?? 0
                )
                guard startOffset < daysInHorizon else { break }
                let dayOffset = context.rng.int(in: startOffset..<daysInHorizon)
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

        return cpRepair(destroyed: Set(destroyedIndices), context: context)
    }

    /// Execute one destroy strategy, returning the indices to rip out.
    /// Each branch is self-contained and produces up to `destroySize`
    /// indices from `includedIndices`. Non-mutating — destruction happens
    /// implicitly later by excluding these from the occupied set.
    private func destroy(
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
            return includedIndices
                .sorted { genes[$0].priority > genes[$1].priority }
                .prefix(destroySize)
                .map { $0 }

        case .random:
            // Fisher–Yates partial shuffle: O(k) instead of full shuffle.
            var pool = includedIndices
            var picked: [Int] = []
            picked.reserveCapacity(destroySize)
            for _ in 0..<min(destroySize, pool.count) {
                let j = context.rng.int(in: 0..<pool.count)
                picked.append(pool[j])
                pool.swapAt(j, pool.count - 1)
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
    private mutating func cpRepair(
        destroyed: Set<Int>,
        context: OptimizerContext
    ) -> IndexSet? {
        let cal = context.calendar
        let horizon = context.planningHorizon

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
        // destroyed dependents (most-constraining-first) then by priority
        // desc so high-value genes commit before low-value ones.
        //
        // Symmetry: skip a variable whose canonical-sym-predecessor is
        // still unassigned. This forces equivalent genes to commit in
        // a fixed (increasing-index) order, pruning the N!-way
        // redundancy.
        func pickNextVariable() -> Int? {
            var best: (idx: Int, size: Int, deg: Int, prio: Double)? = nil
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
                if let cur = best {
                    let tighter = size < cur.size
                    let sizeTie = size == cur.size
                    let moreConstraining = deg > cur.deg
                    let degTie = deg == cur.deg
                    let higherPrio = prio > cur.prio
                    if tighter
                        || (sizeTie && moreConstraining)
                        || (sizeTie && degTie && higherPrio)
                    {
                        best = (idx, size, deg, prio)
                    }
                } else {
                    best = (idx, size, deg, prio)
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
                    genes[idx] = genes[idx].withStartTime(slot)
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
    private mutating func regretRepair(
        destroyed: Set<Int>,
        context: OptimizerContext
    ) -> IndexSet? {
        let cal = context.calendar
        let horizon = context.planningHorizon

        var occupied: [(start: Date, end: Date)] = context.fixedEvents.map {
            ($0.startDate, $0.endDate)
        }
        for (j, gene) in genes.enumerated() where gene.isIncluded && !destroyed.contains(j) {
            occupied.append((gene.startTime, gene.endTime))
        }
        occupied.sort { $0.start < $1.start }

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
                    genesByEvent: genesByEvent
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
                    genesByEvent: genesByEvent
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
                    genes[chosenIdx] = genes[chosenIdx].withStartTime(slot)
                    changed.insert(chosenIdx)
                }
                occupied.append((slot, slot.addingTimeInterval(genes[chosenIdx].duration)))
                occupied.sort { $0.start < $1.start }
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
                    genesByEvent: genesByEvent
                )
                if let slot {
                    if genes[idx].startTime != slot {
                        genes[idx] = genes[idx].withStartTime(slot)
                        changed.insert(idx)
                    }
                    occupied.append((slot, slot.addingTimeInterval(genes[idx].duration)))
                    occupied.sort { $0.start < $1.start }
                }
            }
        }

        return changed.isEmpty ? nil : changed
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
        // Repair moves genes; invalidate cached features.
        cachedFeatures = nil

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

        // Canonicalize equivalent gene groups after
        // structural repair. Stable sort makes the cache fingerprint
        // robust to order-preserving mutations. Safe to run
        // unconditionally — no-op when the order is already canonical.
        SymmetryBreaker.canonicalize(&self)

        needsEvaluation = true
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
