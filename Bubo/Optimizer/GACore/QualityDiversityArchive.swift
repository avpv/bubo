import Foundation

// MARK: - Quality-Diversity Archive (MAP-Elites / CMA-ME / PGA-ME hybrid)
//
// MAP-Elites bins the search space along a small number of "behaviour
// descriptors" and keeps the best individual in each cell. Compared to
// elitism (one best overall), MAP-Elites retains a *portfolio* of
// solutions that span the behaviour space — useful for calendar
// scheduling under user uncertainty: one cell may contain the
// morning-heavy plan, another a deep-work-evening plan, etc.
//
// This implementation blends three ideas:
//
//   • MAP-Elites (Mouret & Clune, 2015): the grid structure, always-
//     replace-if-better update rule.
//   • CMA-ME (Fontaine et al., 2020): "improvement emitters" that sample
//     around archive elites and bias search toward cells the emitter is
//     currently improving. We don't run a full CMA-ES emitter (that would
//     require a separate covariance estimator per cell), but the
//     *improvement signal* is recorded so the GA's selection can
//     weight-draw from productive cells.
//   • PGA-ME (Nilsson & Cully, 2021): gradient-informed offspring. We
//     integrate with `DifferentiableRelaxation` via a callback so a
//     fraction of archive-drawn emigrants get a gradient step before
//     re-entering the population.
//
// Behaviour descriptor: a 3-tuple discretized into the cell index:
//   (focus-block mass, meeting-morning skew, day-spread).
// These are chosen because they (a) correlate with user-visible
// differences between plans and (b) are cheap to compute from the genome.

// MARK: - Behaviour Descriptor

/// 3-dimensional descriptor used as the archive's cell key.
struct BehaviorDescriptor: Hashable, Sendable {
    /// Focus-block minutes as a fraction of total duration. [0, 1].
    let focusMass: Double
    /// Fraction of included events whose start is before noon. [0, 1].
    let morningSkew: Double
    /// Unique days used / horizon days. [0, 1].
    let daySpread: Double

    /// Quantize to a fixed-size grid cell — the MAP-Elites archive key.
    func cell(resolution: Int) -> CellKey {
        let r = max(1, resolution)
        let f = Int((focusMass * Double(r)).rounded(.down))
        let m = Int((morningSkew * Double(r)).rounded(.down))
        let d = Int((daySpread * Double(r)).rounded(.down))
        return CellKey(
            focus: min(r - 1, max(0, f)),
            morning: min(r - 1, max(0, m)),
            day: min(r - 1, max(0, d))
        )
    }

    /// Extract the descriptor directly from a schedule chromosome.
    static func from(_ chromosome: ScheduleChromosome, context: OptimizerContext) -> BehaviorDescriptor {
        let cal = context.calendar
        let horizonStart = cal.startOfDay(for: context.planningHorizon.start)
        let horizonLastDay = cal.startOfDay(for: context.planningHorizon.end.addingTimeInterval(-1))
        let daysInHorizon = max(
            1,
            (cal.dateComponents([.day], from: horizonStart, to: horizonLastDay).day ?? 0) + 1
        )

        var totalMinutes = 0.0
        var focusMinutes = 0.0
        var included = 0
        var morning = 0
        var days: Set<Date> = []

        for gene in chromosome.genes where gene.isIncluded {
            let minutes = gene.duration / 60.0
            totalMinutes += minutes
            if gene.isFocusBlock { focusMinutes += minutes }
            included += 1
            let hour = cal.component(.hour, from: gene.startTime)
            if hour < 12 { morning += 1 }
            days.insert(cal.startOfDay(for: gene.startTime))
        }

        let focusMass = totalMinutes > 0 ? focusMinutes / totalMinutes : 0
        let morningSkew = included > 0 ? Double(morning) / Double(included) : 0
        let daySpread = Double(days.count) / Double(daysInHorizon)

        return BehaviorDescriptor(
            focusMass: clamp(focusMass),
            morningSkew: clamp(morningSkew),
            daySpread: clamp(daySpread)
        )
    }
}

@inline(__always)
private func clamp(_ v: Double) -> Double { max(0, min(1, v)) }

/// Discretized coordinate into the 3D archive grid.
struct CellKey: Hashable, Sendable {
    let focus: Int
    let morning: Int
    let day: Int
}

// MARK: - Archive

/// Quality-Diversity archive. Maintains the best-known chromosome per
/// behaviour cell, plus statistics that drive CMA-ME-style emitter logic.
///
/// Thread safety: mutations go through an `NSLock`. Multi-island GAs
/// share one archive so good solutions discovered on any island are
/// retained globally.
final class QualityDiversityArchive: @unchecked Sendable {
    /// Archive cell entry. Tracks the current incumbent plus improvement
    /// stats used by CMA-ME-style emitter selection.
    struct Cell: Sendable {
        var incumbent: ScheduleChromosome
        /// Fitness at insertion time.
        var fitness: Double
        /// How many times this cell has been improved since creation.
        /// Cells that keep improving are "productive" and emitters draw
        /// from them more often.
        var improvementCount: Int
        /// Most recent fitness delta (positive only). Used to weight
        /// emitter probabilities by recent improvement magnitude.
        var lastDelta: Double
        /// Generation at last improvement. Stale cells can be decayed.
        var lastImprovedGen: Int
    }

    /// Telemetry snapshot.
    struct Telemetry: Sendable {
        let cellCount: Int
        let totalAttempts: Int
        let totalImprovements: Int
        let averageFitness: Double
        let bestFitness: Double
        let coverage: Double   // cellCount / resolution³
    }

    /// Grid resolution per axis. Total cells = resolution³.
    let resolution: Int

    /// Cells keyed by (focus, morning, day).
    private var cells: [CellKey: Cell] = [:]
    private let lock = NSLock()

    private var totalAttempts: Int = 0
    private var totalImprovements: Int = 0
    private(set) var generation: Int = 0

    init(resolution: Int = 6) {
        self.resolution = max(2, resolution)
    }

    // MARK: - Insert

    /// Try to insert `chromosome` into its behaviour cell.
    ///
    /// Insertion rule:
    ///   • New cell: always accept.
    ///   • Existing cell: accept only if `chromosome.rawFitness` beats
    ///     the incumbent by more than `epsilonMargin`. A margin avoids
    ///     noise-level churn that would inflate `improvementCount`.
    ///
    /// Returns whether the chromosome was inserted, and by how much it
    /// improved over the incumbent (0 for fresh cells).
    @discardableResult
    func consider(
        _ chromosome: ScheduleChromosome,
        descriptor: BehaviorDescriptor,
        epsilonMargin: Double = 1e-4
    ) -> (inserted: Bool, delta: Double) {
        lock.lock()
        defer { lock.unlock() }
        totalAttempts += 1

        let key = descriptor.cell(resolution: resolution)
        let fit = chromosome.rawFitness

        if let existing = cells[key] {
            let delta = fit - existing.fitness
            guard delta > epsilonMargin else { return (false, 0) }
            var updated = existing
            updated.incumbent = chromosome
            updated.fitness = fit
            updated.improvementCount += 1
            updated.lastDelta = delta
            updated.lastImprovedGen = generation
            cells[key] = updated
            totalImprovements += 1
            return (true, delta)
        }

        // Fresh cell.
        cells[key] = Cell(
            incumbent: chromosome,
            fitness: fit,
            improvementCount: 0,
            lastDelta: 0,
            lastImprovedGen: generation
        )
        return (true, 0)
    }

    /// Advance the archive's logical generation counter. Called once per
    /// GA generation by the host loop so staleness-based decay has a
    /// reference clock.
    func tick() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
    }

    // MARK: - Query

    /// Snapshot of every incumbent, sorted by descending fitness. Callers
    /// use this to seed new populations or harvest a diverse Pareto-like
    /// set at the end of evolution.
    var incumbents: [ScheduleChromosome] {
        lock.lock()
        defer { lock.unlock() }
        return cells.values
            .sorted { $0.fitness > $1.fitness }
            .map(\.incumbent)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return cells.count
    }

    /// Sample an incumbent weighted by CMA-ME-style productivity.
    ///
    /// Weights are `max(1e-3, improvementCount + lastDelta · 100)`. Cells
    /// that keep improving get more draws; fresh cells still have a nonzero
    /// baseline so the archive stays mixable.
    func sampleProductiveIncumbent(rng: GARandom) -> ScheduleChromosome? {
        lock.lock()
        defer { lock.unlock() }
        guard !cells.isEmpty else { return nil }

        var weightSum = 0.0
        var weighted: [(ScheduleChromosome, Double)] = []
        weighted.reserveCapacity(cells.count)
        for cell in cells.values {
            let stalePenalty = max(0.1, 1.0 - Double(generation - cell.lastImprovedGen) * 0.02)
            let weight = max(1e-3, Double(cell.improvementCount) + cell.lastDelta * 100.0) * stalePenalty
            weighted.append((cell.incumbent, weight))
            weightSum += weight
        }
        guard weightSum > 1e-12 else {
            return weighted.first?.0
        }

        var r = rng.double(in: 0..<weightSum)
        for (chromosome, w) in weighted {
            r -= w
            if r <= 0 { return chromosome }
        }
        return weighted.last?.0
    }

    /// Sample a uniformly random incumbent — useful for diversity injection
    /// when the GA wants an unbiased mix rather than productivity-weighted.
    func sampleUniform(rng: GARandom) -> ScheduleChromosome? {
        lock.lock()
        defer { lock.unlock() }
        guard !cells.isEmpty else { return nil }
        let idx = rng.int(in: 0..<cells.count)
        let cell = Array(cells.values)[idx]
        return cell.incumbent
    }

    var telemetry: Telemetry {
        lock.lock()
        defer { lock.unlock() }
        let fitnesses = cells.values.map(\.fitness)
        let avg = fitnesses.isEmpty ? 0 : fitnesses.reduce(0, +) / Double(fitnesses.count)
        let best = fitnesses.max() ?? 0
        let capacity = resolution * resolution * resolution
        return Telemetry(
            cellCount: cells.count,
            totalAttempts: totalAttempts,
            totalImprovements: totalImprovements,
            averageFitness: avg,
            bestFitness: best,
            coverage: Double(cells.count) / Double(max(1, capacity))
        )
    }

    // MARK: - Population injection

    /// Return up to `count` incumbents drawn by productivity weighting.
    /// Used by the GA to seed a fraction of the next generation with
    /// diverse archive members — the "MAP-Elites emitter" step.
    func drawEmitters(count: Int, rng: GARandom) -> [ScheduleChromosome] {
        var out: [ScheduleChromosome] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            if let c = sampleProductiveIncumbent(rng: rng) {
                out.append(c)
            } else {
                break
            }
        }
        return out
    }
}
