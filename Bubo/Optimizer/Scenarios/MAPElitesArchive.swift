import Foundation

// MARK: - MAP-Elites Archive
//
// Quality-diversity archive replacing the previous "pick top-K diverse from
// the final population" sampling. Divides the behaviour space into a fixed
// grid of cells and keeps the best individual per cell. The archive naturally
// yields a diverse set of high-quality schedules (one per occupied cell), and
// scenarios returned to the user are simply the most-populated / highest-
// scoring cells sorted by fitness.
//
// Feature space (5 × 5 × 5 = 125 cells):
// • focusQuality: longest uninterrupted focus block per day, averaged across
//   days, normalized against the user's `idealFocusBlockMinutes`. Captures
//   "does this schedule protect deep-work time?"
// • meetingDensity: fraction of working hours occupied by meeting-context
//   events. Captures "how packed is the day with meetings?"
// • inclusionRatio: fraction of droppable events that were included.
//   Captures "did we pack the schedule or drop tasks?"
//
// Every feature is clamped to [0, 1] and binned into 5 uniform slots. Two
// schedules that differ on the same objective but land in the same cell will
// compete — the higher-fitness one wins. A schedule that lands in a new cell
// is admitted regardless of fitness so we don't lose a diverse alternative
// just because it's a few percent weaker on the scalar.

// MARK: - Features

struct MAPElitesFeatures: Hashable, Sendable {
    /// 0–1 (clamped). Longer protected focus blocks per day → higher score.
    let focusQuality: Double
    /// 0–1 (clamped). More working-hour minutes marked as meetings → higher score.
    let meetingDensity: Double
    /// 0–1. Droppable events included / total droppable events (1.0 if none).
    let inclusionRatio: Double

    /// Bin each feature into `bins` equal-width slots so identical cells
    /// collide in a dictionary lookup. `bins` defaults to 5 per dimension.
    func cell(bins: Int) -> MAPElitesCell {
        MAPElitesCell(
            focusBin: Self.bin(focusQuality, bins: bins),
            meetingBin: Self.bin(meetingDensity, bins: bins),
            inclusionBin: Self.bin(inclusionRatio, bins: bins)
        )
    }

    private static func bin(_ value: Double, bins: Int) -> Int {
        let clamped = max(0, min(1, value))
        // Map [0, 1] → [0, bins-1] with an inclusive upper edge so 1.0 lands
        // in the last cell rather than overflowing.
        let idx = Int(clamped * Double(bins))
        return min(bins - 1, idx)
    }
}

struct MAPElitesCell: Hashable, Sendable {
    let focusBin: Int
    let meetingBin: Int
    let inclusionBin: Int
}

// MARK: - Archive

struct MAPElitesArchive {
    /// Bins per feature axis. 5 × 5 × 5 = 125 cells; small enough that even
    /// modest population sizes fill a meaningful fraction.
    let binsPerAxis: Int

    /// Cached best-per-cell. Fitness here is the raw scalar fitness from
    /// the evaluator so we can compare two chromosomes that happen to land
    /// in the same cell without re-running any objective.
    private(set) var cells: [MAPElitesCell: ScheduleChromosome] = [:]

    init(binsPerAxis: Int = 5) {
        self.binsPerAxis = binsPerAxis
    }

    /// Submit a candidate. Admitted if:
    ///   (a) the target cell is empty, or
    ///   (b) the incumbent fitness is lower (higher-is-better).
    @discardableResult
    mutating func deposit(
        _ chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> Bool {
        let features = Self.features(for: chromosome, context: context)
        let key = features.cell(bins: binsPerAxis)
        if let incumbent = cells[key], incumbent.rawFitness >= chromosome.rawFitness {
            return false
        }
        cells[key] = chromosome
        return true
    }

    /// Submit a whole population at once. Order matters only for deterministic
    /// tiebreaking when two chromosomes in the same cell have identical
    /// rawFitness — earlier arrivals keep the cell.
    mutating func depositAll(
        _ population: [ScheduleChromosome],
        context: OptimizerContext
    ) {
        for chromosome in population {
            _ = deposit(chromosome, context: context)
        }
    }

    // MARK: - Readout

    /// Number of currently occupied cells. Useful for diversity telemetry.
    var occupiedCount: Int { cells.count }

    /// Total grid capacity (for diagnostics).
    var capacity: Int { binsPerAxis * binsPerAxis * binsPerAxis }

    /// All occupied cells sorted by fitness descending. Primary index for
    /// scenario generation.
    var sortedByFitness: [(cell: MAPElitesCell, individual: ScheduleChromosome)] {
        cells
            .map { (cell: $0.key, individual: $0.value) }
            .sorted { $0.individual.rawFitness > $1.individual.rawFitness }
    }

    /// Produce up to `count` diverse scenarios. The best-fitness individual
    /// is always included; remaining slots are filled by walking cells in
    /// descending fitness order, picking cells that are not adjacent to
    /// already-chosen cells (Manhattan distance ≥ 1 on at least two axes).
    ///
    /// When fewer than `count` distinct cells are available, the fallback
    /// widens the diversity relaxation twice: strict (≥ 2 axes differ) →
    /// loose (≥ 1 axis differs) → any remaining cell. This preserves the
    /// previous ScenarioGenerator behaviour where the user always got the
    /// requested number of scenarios if the population supported it.
    func diverseScenarios(
        count: Int,
        evaluator: FitnessEvaluator,
        context: OptimizerContext
    ) -> [ScheduleScenario] {
        guard count > 0, !cells.isEmpty else { return [] }
        let sorted = sortedByFitness
        guard let first = sorted.first else { return [] }

        var chosen: [(MAPElitesCell, ScheduleChromosome)] = [first]
        var attemptedStrictness = 0

        while chosen.count < count && attemptedStrictness < 3 {
            for candidate in sorted {
                if chosen.count >= count { break }
                if chosen.contains(where: { $0.0 == candidate.cell }) { continue }
                let meetsStrictness: Bool
                switch attemptedStrictness {
                case 0:
                    meetsStrictness = chosen.allSatisfy { axisDistance($0.0, candidate.cell) >= 2 }
                case 1:
                    meetsStrictness = chosen.allSatisfy { axisDistance($0.0, candidate.cell) >= 1 }
                default:
                    meetsStrictness = true
                }
                if meetsStrictness {
                    chosen.append(candidate)
                }
            }
            attemptedStrictness += 1
        }

        return chosen.map { (_, chromosome) in
            ScheduleScenario(
                genes: chromosome.genes,
                fitness: chromosome.rawFitness,
                objectiveBreakdown: chromosome.objectiveCache
                    ?? evaluator.objectiveBreakdown(for: chromosome, context: context),
                constraintViolations: evaluator.constraintEngine.violations(
                    for: chromosome,
                    context: context
                )
            )
        }
    }

    /// Count of feature-axes where two cells differ. 0 = identical, 3 = all
    /// three axes differ. Used for diverse-scenario selection strictness.
    private func axisDistance(_ a: MAPElitesCell, _ b: MAPElitesCell) -> Int {
        var count = 0
        if a.focusBin != b.focusBin { count += 1 }
        if a.meetingBin != b.meetingBin { count += 1 }
        if a.inclusionBin != b.inclusionBin { count += 1 }
        return count
    }

    // MARK: - Feature extraction

    /// Derive behaviour-space features from the schedule itself. Feature
    /// extraction is deliberately cheap (O(N) over genes, no constraint
    /// engine reruns) so depositing during evolution is viable.
    static func features(
        for chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> MAPElitesFeatures {
        let cal = context.calendar
        let workingMinutes = Double((context.workingHours.upperBound - context.workingHours.lowerBound) * 60)
        let idealFocus = max(30.0, Double(context.preferences.idealFocusBlockMinutes))

        // Per-day bucketing of included genes + fixed events.
        var eventsByDay: [Date: [(start: Date, end: Date, isMeeting: Bool)]] = [:]
        for event in context.fixedEvents {
            let day = cal.startOfDay(for: event.startDate)
            let meetingish = Self.isMeetingContext(event.resolvedContext())
            eventsByDay[day, default: []].append((event.startDate, event.endDate, meetingish))
        }
        for gene in chromosome.genes where gene.isIncluded {
            let day = cal.startOfDay(for: gene.startTime)
            eventsByDay[day, default: []].append(
                (gene.startTime, gene.endTime, Self.isMeetingContext(gene.context))
            )
        }

        // focusQuality: longest gap between events per day, normalized to
        // idealFocusBlockMinutes. Averaged across populated days.
        var focusSum = 0.0
        var focusDays = 0
        var meetingSum = 0.0
        for (day, events) in eventsByDay {
            guard let workStart = cal.date(bySettingHour: context.workingHours.lowerBound, minute: 0, second: 0, of: day),
                  let workEnd = cal.date(bySettingHour: context.workingHours.upperBound, minute: 0, second: 0, of: day)
            else { continue }

            let sorted = events.sorted { $0.start < $1.start }
            var longestGap: TimeInterval = 0
            var cursor = workStart
            for event in sorted {
                let eventStart = max(event.start, workStart)
                let eventEnd = min(event.end, workEnd)
                guard eventStart < workEnd && eventEnd > workStart else { continue }
                if eventStart > cursor {
                    longestGap = max(longestGap, eventStart.timeIntervalSince(cursor))
                }
                cursor = max(cursor, eventEnd)
            }
            if cursor < workEnd {
                longestGap = max(longestGap, workEnd.timeIntervalSince(cursor))
            }
            focusSum += min(1.0, (longestGap / 60.0) / idealFocus)
            focusDays += 1

            // Meeting minutes per day, normalized to working minutes.
            let meetingMinutes = sorted
                .filter(\.isMeeting)
                .map { min($0.end, workEnd).timeIntervalSince(max($0.start, workStart)) / 60.0 }
                .reduce(0, +)
            meetingSum += min(1.0, meetingMinutes / workingMinutes)
        }

        let focusQuality = focusDays > 0 ? focusSum / Double(focusDays) : 0.5
        let meetingDensity = focusDays > 0 ? meetingSum / Double(focusDays) : 0.0

        // inclusionRatio: fraction of droppable genes actually included.
        // If the schedule contains no droppable genes, default to 1.0 so
        // the feature doesn't spuriously push every candidate into the
        // same cell.
        let droppable = chromosome.genes.filter(\.isDroppable)
        let inclusionRatio: Double
        if droppable.isEmpty {
            inclusionRatio = 1.0
        } else {
            inclusionRatio = Double(droppable.count(where: \.isIncluded)) / Double(droppable.count)
        }

        return MAPElitesFeatures(
            focusQuality: focusQuality,
            meetingDensity: meetingDensity,
            inclusionRatio: inclusionRatio
        )
    }

    /// Treat anything tagged `meeting` (case-insensitive, prefix-level) as
    /// a meeting for density accounting. Matches `ContextSwitchObjective`'s
    /// prefix semantics so the archive's features and the objective's
    /// scoring stay in sync.
    private static func isMeetingContext(_ context: String?) -> Bool {
        guard let context else { return false }
        let lower = context.lowercased()
        return lower.hasPrefix("meeting") || lower.contains("/meeting")
    }
}
