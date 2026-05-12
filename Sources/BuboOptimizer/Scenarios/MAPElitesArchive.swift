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
// Feature space (5 × 5 × 5 = 125 cells) — chosen to actually VARY across
// different placements of the same task set:
//
// • taskSpreadDays: distinct days hosting movable tasks / working days in
//   horizon. Separates "all tasks today" from "tasks spread across the week".
//
// • morningShare: fraction of movable-task hours scheduled before 12:00.
//   Separates "morning-heavy" from "afternoon-heavy" layouts.
//
// • lastTaskHour: hour-of-day of the latest-ending movable task, normalized
//   over the working-hours window. Separates "finish by lunch" from "work
//   late" layouts.
//
// The previous axes (focusQuality, meetingDensity, inclusionRatio) were all
// dominated by FIXED-event content — on a typical week with 20 meetings,
// every candidate schedule landed in the same cell regardless of where the
// user's 4 movable tasks went, so `scenarios=3` surfaced only 1 cell. The
// new triple is defined purely over movable placements, so variations in
// task arrangement actually populate distinct cells.
//
// Every feature is clamped to [0, 1] and binned into 5 uniform slots. Two
// schedules that differ on the same objective but land in the same cell will
// compete — the higher-fitness one wins. A schedule that lands in a new cell
// is admitted regardless of fitness so we don't lose a diverse alternative
// just because it's a few percent weaker on the scalar.

// MARK: - Features

public struct MAPElitesFeatures: Hashable, Sendable {
    /// 0–1. Distinct days with movable tasks / working days in horizon.
    /// 0 = no movables, 1 = every working day has at least one task.
    public let taskSpreadDays: Double
    /// 0–1. Minutes of movable work scheduled before 12:00 / total
    /// movable minutes. 0 = everything afternoon, 1 = everything morning.
    public let morningShare: Double
    /// 0–1. Latest-ending movable task's hour-of-day normalized over
    /// working hours. 0 = ends at workingHours.lowerBound, 1 = ends at
    /// workingHours.upperBound.
    public let lastTaskHour: Double

    /// Bin each feature into `bins` equal-width slots so identical cells
    /// collide in a dictionary lookup. `bins` defaults to 5 per dimension.
    public func cell(bins: Int) -> MAPElitesCell {
        MAPElitesCell(
            spreadBin: Self.bin(taskSpreadDays, bins: bins),
            morningBin: Self.bin(morningShare, bins: bins),
            lastHourBin: Self.bin(lastTaskHour, bins: bins)
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

public struct MAPElitesCell: Hashable, Sendable {
    public let spreadBin: Int
    public let morningBin: Int
    public let lastHourBin: Int
}

// MARK: - Archive

public struct MAPElitesArchive {
    /// Bins per feature axis. 5 × 5 × 5 = 125 cells; small enough that even
    /// modest population sizes fill a meaningful fraction.
    public let binsPerAxis: Int

    /// Cached best-per-cell. Fitness here is the raw scalar fitness from
    /// the evaluator so we can compare two chromosomes that happen to land
    /// in the same cell without re-running any objective.
    private(set) var cells: [MAPElitesCell: ScheduleChromosome] = [:]

    public init(binsPerAxis: Int = 5) {
        self.binsPerAxis = binsPerAxis
    }

    /// Submit a candidate. Admitted if:
    ///   (a) the target cell is empty, or
    ///   (b) the incumbent fitness is lower (higher-is-better).
    @discardableResult
    public mutating func deposit(
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
    public mutating func depositAll(
        _ population: [ScheduleChromosome],
        context: OptimizerContext
    ) {
        for chromosome in population {
            _ = deposit(chromosome, context: context)
        }
    }

    // MARK: - Readout

    /// Number of currently occupied cells. Useful for diversity telemetry.
    public var occupiedCount: Int { cells.count }

    /// Total grid capacity (for diagnostics).
    public var capacity: Int { binsPerAxis * binsPerAxis * binsPerAxis }

    /// All occupied cells sorted by fitness descending. Primary index for
    /// scenario generation.
    public var sortedByFitness: [(cell: MAPElitesCell, individual: ScheduleChromosome)] {
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
    public func diverseScenarios(
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
        if a.spreadBin != b.spreadBin { count += 1 }
        if a.morningBin != b.morningBin { count += 1 }
        if a.lastHourBin != b.lastHourBin { count += 1 }
        return count
    }

    // MARK: - Feature extraction

    /// Derive behaviour-space features from the schedule itself. Feature
    /// extraction is deliberately cheap (O(N) over genes, no constraint
    /// engine reruns) so depositing during evolution is viable.
    public static func features(
        for chromosome: ScheduleChromosome,
        context: OptimizerContext
    ) -> MAPElitesFeatures {
        let cal = context.calendar

        // Collect included movable genes once — every axis reads from
        // this slice, so no repeated scans.
        let active = chromosome.genes.filter(\.isIncluded)

        // Axis 1: taskSpreadDays
        // Distinct-day count / working days in horizon, so "all tasks
        // on one day" → 1/5 = 0.2 and "tasks on each of 5 working days"
        // → 1.0. Normalizing over working days (not total days) keeps
        // the axis usable for horizons that span weekends.
        let workingDayCount = Self.workingDaysInHorizon(context: context, calendar: cal)
        var uniqueDays = Set<Date>()
        for gene in active {
            uniqueDays.insert(cal.startOfDay(for: gene.startTime))
        }
        let taskSpreadDays: Double
        if workingDayCount > 0 {
            taskSpreadDays = min(1.0, Double(uniqueDays.count) / Double(workingDayCount))
        } else {
            taskSpreadDays = 0
        }

        // Axis 2: morningShare
        // Fraction of movable-task minutes that fall before 12:00.
        // Reports 0.5 (neutral) when there are no included movables so
        // empty schedules don't all pile into the same corner cell.
        //
        // Date-based comparison instead of hour-only: a gene ending at
        // 12:30 has `endHour == 12` but is not wholly-morning. Comparing
        // `gene.endTime <= noon` correctly classifies that as straddling
        // noon so only the 30 pre-noon minutes get credited.
        var totalMinutes = 0.0
        var morningMinutes = 0.0
        let noonHour = 12
        for gene in active {
            let duration = gene.endTime.timeIntervalSince(gene.startTime) / 60.0
            guard duration > 0 else { continue }
            totalMinutes += duration
            let dayStart = cal.startOfDay(for: gene.startTime)
            guard let noon = cal.date(bySettingHour: noonHour, minute: 0, second: 0, of: dayStart) else { continue }
            if gene.endTime <= noon {
                morningMinutes += duration
            } else if gene.startTime >= noon {
                // wholly afternoon — no contribution
            } else {
                // Straddles noon — credit only the pre-noon slice.
                let clipped = noon.timeIntervalSince(gene.startTime) / 60.0
                morningMinutes += max(0, clipped)
            }
        }
        let morningShare: Double
        if totalMinutes > 0 {
            morningShare = min(1.0, morningMinutes / totalMinutes)
        } else {
            morningShare = 0.5
        }

        // Axis 3: lastTaskHour
        // Time-of-day of the latest-ending movable task, normalized
        // over the working-hours span. Neutral 0.5 when the schedule
        // has no movables.
        let lowerHour = context.workingHours.lowerBound
        let upperHour = context.workingHours.upperBound
        let workingSpan = max(1, upperHour - lowerHour)
        var latestEndHour: Double?
        for gene in active {
            let h = Double(cal.component(.hour, from: gene.endTime))
            let m = Double(cal.component(.minute, from: gene.endTime))
            let decimal = h + m / 60.0
            if let curr = latestEndHour {
                latestEndHour = max(curr, decimal)
            } else {
                latestEndHour = decimal
            }
        }
        let lastTaskHour: Double
        if let latest = latestEndHour {
            let normalized = (latest - Double(lowerHour)) / Double(workingSpan)
            lastTaskHour = max(0, min(1, normalized))
        } else {
            lastTaskHour = 0.5
        }

        return MAPElitesFeatures(
            taskSpreadDays: taskSpreadDays,
            morningShare: morningShare,
            lastTaskHour: lastTaskHour
        )
    }

    /// Count of working days inside the planning horizon. Working-day
    /// membership comes from `preferences.workingDays`; empty set means
    /// every weekday counts (same convention as the rest of the
    /// optimizer).
    private static func workingDaysInHorizon(
        context: OptimizerContext,
        calendar: Calendar
    ) -> Int {
        let horizon = context.planningHorizon
        let startDay = calendar.startOfDay(for: horizon.start)
        let lastDay = calendar.startOfDay(for: horizon.end.addingTimeInterval(-1))
        let totalDays = max(1, (calendar.dateComponents([.day], from: startDay, to: lastDay).day ?? 0) + 1)
        let workingDays = context.preferences.workingDays
        if workingDays.isEmpty { return totalDays }
        var count = 0
        for offset in 0..<totalDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            if workingDays.contains(weekday) { count += 1 }
        }
        return count
    }
}
