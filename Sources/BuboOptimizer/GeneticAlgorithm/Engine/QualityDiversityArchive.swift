import Foundation

// MARK: - Quality-Diversity Archive (MAP-Elites)
//
// MAP-Elites bins the search space along a small number of behaviour
// descriptors and keeps the best individual in each cell (Mouret &
// Clune, 2015). For Bubo's calendar optimizer the descriptor is a
// 3-tuple: (focusMass, morningSkew, daySpread), read directly from
// `ScheduleFeatureVector.behavior` so feature extraction is shared
// with the surrogate model.
//
// On top of vanilla MAP-Elites this implementation tracks per-cell
// improvement statistics so emitter sampling biases toward
// historically-productive cells. That's a borrowing of CMA-ME's
// "improvement emitter" intuition (Fontaine et al., 2020) — we don't
// run a CMA-ES sampler per cell (that would require a covariance
// matrix per archive entry; way too expensive for live calendar
// planning), so the honest framing is "MAP-Elites with productivity-
// weighted emitter sampling," not "CMA-ME."

// MARK: - Behaviour Descriptor

/// 4-dimensional descriptor used as the archive's cell key.
///
/// `precedenceTightness` is the fourth axis (added for the graph
/// improvements): the fraction of direct `dependsOn` edges whose
/// dependent is placed within one working day of the prerequisite's
/// end. Together with the classical three axes it captures how
/// "graph-respecting" a schedule is, so the emitter can keep diverse
/// tightness regimes alive rather than collapsing to whichever one
/// the soft `PrecedenceObjective` happens to like first.
public struct BehaviorDescriptor: Hashable, Sendable {

    public init(
        focusMass: Double,
        morningSkew: Double,
        daySpread: Double,
        precedenceTightness: Double
    ) {
        self.focusMass = focusMass
        self.morningSkew = morningSkew
        self.daySpread = daySpread
        self.precedenceTightness = precedenceTightness
    }

    /// Focus-block minutes as a fraction of total duration. [0, 1].
    public let focusMass: Double
    /// Fraction of included events whose start is before noon. [0, 1].
    public let morningSkew: Double
    /// Unique days used / horizon days. [0, 1].
    public let daySpread: Double
    /// Fraction of direct precedence pairs placed "tightly" (gap within
    /// one working day). 1.0 = every chain packed; 0.0 = every chain
    /// sprawls. Schedules without precedence edges clamp to 0 and
    /// collapse onto one slice of the axis — no harm, just a reduced
    /// bin count for unconstrained workloads.
    public let precedenceTightness: Double

    /// Quantize to a fixed-size grid cell — the MAP-Elites archive key.
    public func cell(resolution: Int) -> CellKey {
        let r = max(1, resolution)
        let f = Int((focusMass * Double(r)).rounded(.down))
        let m = Int((morningSkew * Double(r)).rounded(.down))
        let d = Int((daySpread * Double(r)).rounded(.down))
        let p = Int((precedenceTightness * Double(r)).rounded(.down))
        return CellKey(
            focus: min(r - 1, max(0, f)),
            morning: min(r - 1, max(0, m)),
            day: min(r - 1, max(0, d)),
            precedence: min(r - 1, max(0, p))
        )
    }

    /// Extract the descriptor from a chromosome via the shared feature
    /// extractor. Precedence-tightness is computed against the
    /// context's conflict graph when available — absent graph = 0, so
    /// callers that don't wire up `ScheduleConflictGraph` see the
    /// archive behave like the 3D version.
    public static func from(_ chromosome: ScheduleChromosome, context: OptimizerContext) -> BehaviorDescriptor {
        let base = ScheduleFeatureVector.extract(chromosome, context: context).behavior
        let tightness = context.ensureConflictGraph().precedenceTightness(for: chromosome)
        return BehaviorDescriptor(
            focusMass: base.focusMass,
            morningSkew: base.morningSkew,
            daySpread: base.daySpread,
            precedenceTightness: max(0, min(1, tightness))
        )
    }
}

/// Discretized coordinate into the 4D archive grid.
public struct CellKey: Hashable, Sendable {

    public init(
        focus: Int,
        morning: Int,
        day: Int,
        precedence: Int
    ) {
        self.focus = focus
        self.morning = morning
        self.day = day
        self.precedence = precedence
    }

    public let focus: Int
    public let morning: Int
    public let day: Int
    public let precedence: Int
}

// MARK: - Archive

/// MAP-Elites archive with productivity-weighted emitter sampling.
///
/// Thread safety: mutations and reads go through an `NSLock`.
/// Multi-island GAs share one archive so good solutions discovered on
/// any island are retained globally.
public final class QualityDiversityArchive: @unchecked Sendable {
    /// Archive cell entry. Tracks the current incumbent plus
    /// improvement statistics that drive emitter selection.
    public struct Cell: Sendable {

        public init(
            incumbent: ScheduleChromosome,
            fitness: Double,
            improvementCount: Int,
            lastDelta: Double,
            lastImprovedGen: Int
        ) {
            self.incumbent = incumbent
            self.fitness = fitness
            self.improvementCount = improvementCount
            self.lastDelta = lastDelta
            self.lastImprovedGen = lastImprovedGen
        }

        public var incumbent: ScheduleChromosome
        /// Fitness at insertion time.
        public var fitness: Double
        /// How many times this cell has been improved since creation.
        /// Cells that keep improving are "productive" and get drawn
        /// from more often.
        public var improvementCount: Int
        /// Most recent fitness delta (positive only). Weights the
        /// emitter draw by recent improvement magnitude.
        public var lastDelta: Double
        /// Generation of the most recent improvement. Stale cells decay
        /// in their emitter weight over time.
        public var lastImprovedGen: Int
    }

    /// Telemetry snapshot for diagnostics and tests.
    public struct Telemetry: Sendable {

        public init(
            cellCount: Int,
            totalAttempts: Int,
            totalImprovements: Int,
            averageFitness: Double,
            bestFitness: Double,
            coverage: Double
        ) {
            self.cellCount = cellCount
            self.totalAttempts = totalAttempts
            self.totalImprovements = totalImprovements
            self.averageFitness = averageFitness
            self.bestFitness = bestFitness
            self.coverage = coverage
        }

        public let cellCount: Int
        public let totalAttempts: Int
        public let totalImprovements: Int
        public let averageFitness: Double
        public let bestFitness: Double
        /// `cellCount / resolution³`.
        public let coverage: Double
    }

    /// Grid resolution per axis. Total cells = resolution³.
    public let resolution: Int

    /// Cells keyed by (focus, morning, day).
    private var cells: [CellKey: Cell] = [:]
    private let lock = NSLock()

    private var totalAttempts: Int = 0
    private var totalImprovements: Int = 0
    private(set) var generation: Int = 0

    public init(resolution: Int = 6) {
        self.resolution = max(2, resolution)
    }

    // MARK: - Insert

    /// Try to insert `chromosome` into its behaviour cell.
    ///
    /// Insertion rule:
    ///   • Empty cell: always accept.
    ///   • Existing cell: accept only if the new fitness beats the
    ///     incumbent by more than `epsilonMargin`. The margin avoids
    ///     noise-level churn that would inflate `improvementCount`.
    ///
    /// Returns whether the chromosome was inserted and by how much it
    /// improved over the incumbent (0 for fresh cells).
    @discardableResult
    public func consider(
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

        cells[key] = Cell(
            incumbent: chromosome,
            fitness: fit,
            improvementCount: 0,
            lastDelta: 0,
            lastImprovedGen: generation
        )
        return (true, 0)
    }

    /// Advance the archive's logical generation counter. Called once
    /// per GA generation so staleness-based decay has a reference clock.
    public func tick() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
    }

    // MARK: - Query

    /// Snapshot of every incumbent, sorted by descending fitness.
    /// Callers use this to seed new populations or harvest a diverse
    /// Pareto-like set at the end of evolution.
    public var incumbents: [ScheduleChromosome] {
        lock.lock()
        defer { lock.unlock() }
        return cells.values
            .sorted { $0.fitness > $1.fitness }
            .map(\.incumbent)
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return cells.count
    }

    /// Sample an incumbent weighted by productivity:
    ///   `weight = (improvementCount + lastDelta · 100) · staleDecay`
    /// where `staleDecay = max(0.1, 1 - 0.02 · generationsSinceImprovement)`.
    /// Cells that keep improving get more draws; stale cells decay
    /// toward a 10% floor so the archive stays mixable.
    public func sampleProductiveIncumbent(rng: GARandom) -> ScheduleChromosome? {
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

    /// Sample a uniformly random incumbent — useful for diversity
    /// injection when the GA wants an unbiased mix.
    public func sampleUniform(rng: GARandom) -> ScheduleChromosome? {
        lock.lock()
        defer { lock.unlock() }
        guard !cells.isEmpty else { return nil }
        let idx = rng.int(in: 0..<cells.count)
        let cell = Array(cells.values)[idx]
        return cell.incumbent
    }

    public var telemetry: Telemetry {
        lock.lock()
        defer { lock.unlock() }
        let fitnesses = cells.values.map(\.fitness)
        let avg = fitnesses.isEmpty ? 0 : fitnesses.reduce(0, +) / Double(fitnesses.count)
        let best = fitnesses.max() ?? 0
        // 4D archive: capacity = resolution⁴. Use Int64 to stay safe
        // at higher resolutions (6⁴ = 1296, 8⁴ = 4096, both fit
        // Int, but large res values on-device would overflow Int32).
        let r = Int64(resolution)
        let capacity = r * r * r * r
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
    /// Used by the schedule-specific generation hook to inject archive
    /// emitters into the next generation.
    public func drawEmitters(count: Int, rng: GARandom) -> [ScheduleChromosome] {
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
