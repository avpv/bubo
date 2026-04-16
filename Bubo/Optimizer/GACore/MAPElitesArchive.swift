import Foundation

// MARK: - MAP-Elites Archive

/// Quality-Diversity archive: a grid of "cells" in 4-D behaviour space
/// (`BehaviorDescriptor`), each holding the highest-fitness chromosome
/// that mapped to that cell across the run. The GA itself still selects
/// toward raw fitness — MAP-Elites runs alongside, observing every
/// evaluated individual and filing it in the right cell. At the end of
/// the run the archive represents a set of high-quality schedules that
/// cover distinct *styles*: deep-work days, meeting-heavy days, smooth
/// energy days, etc.
///
/// Product-level win: instead of returning one "best" schedule, we can
/// surface the elites of neighbouring cells as alternatives the user can
/// pick between. Under the hood it also doubles as a warm-start source
/// for `IncrementalReoptimizer` — the nearest cell to the pre-drag
/// descriptor is almost always the best place to start re-optimising.
///
/// Thread safety: one `NSLock`. `MAPElitesArchive` is shared across
/// islands when `GAConfiguration.enableMAPElites` is on.
final class MAPElitesArchive: @unchecked Sendable {
    /// Grid resolution per descriptor dimension. Total cells = res^4. Keep
    /// small; res=6 → 1296 cells, which is plenty of coverage for the
    /// 4-D behaviour space while fitting comfortably in memory.
    let resolution: Int

    private var cells: [CellKey: ScheduleChromosome] = [:]
    private let lock = NSLock()

    struct CellKey: Hashable {
        let focus: Int
        let density: Int
        let energy: Int
        let switches: Int
    }

    init(resolution: Int = 6) {
        self.resolution = max(2, resolution)
    }

    /// Bin a 4-D descriptor into a discrete grid cell. The `min(res-1, …)`
    /// clamp handles the rare case of a value exactly equal to 1.0, which
    /// would otherwise land one cell past the end.
    func cell(for descriptor: BehaviorDescriptor) -> CellKey {
        func bin(_ v: Double) -> Int {
            let clamped = min(1.0, max(0.0, v))
            return min(resolution - 1, Int(clamped * Double(resolution)))
        }
        return CellKey(
            focus: bin(descriptor.focusFraction),
            density: bin(descriptor.meetingDensity),
            energy: bin(descriptor.energyFit),
            switches: bin(descriptor.contextSwitches)
        )
    }

    /// Offer a chromosome to the archive. Replaces the incumbent of its
    /// cell only when the challenger has strictly higher `rawFitness`.
    /// Returns the cell key so callers can log coverage changes.
    @discardableResult
    func admit(_ chromosome: ScheduleChromosome, descriptor: BehaviorDescriptor) -> CellKey {
        let key = cell(for: descriptor)
        lock.lock()
        defer { lock.unlock() }
        if let incumbent = cells[key] {
            if chromosome.rawFitness > incumbent.rawFitness {
                cells[key] = chromosome
            }
        } else {
            cells[key] = chromosome
        }
        return key
    }

    /// Find the archive elite closest in descriptor space to `target`.
    /// Used by `IncrementalReoptimizer` to warm-start from a semantically
    /// similar schedule after a drag-reflow. Returns nil when the archive
    /// is empty.
    func nearest(to target: BehaviorDescriptor, context: OptimizerContext) -> ScheduleChromosome? {
        lock.lock()
        let snapshot = cells
        lock.unlock()
        guard !snapshot.isEmpty else { return nil }

        var bestChromo: ScheduleChromosome?
        var bestDist = Double.infinity
        for (_, elite) in snapshot {
            let eliteDesc = BehaviorDescriptor(chromosome: elite, context: context)
            let d = eliteDesc.distance(to: target)
            if d < bestDist {
                bestDist = d
                bestChromo = elite
            }
        }
        return bestChromo
    }

    /// Draw up to `count` seed chromosomes spread across the archive for
    /// warm-starting a fresh GA run. Picks the top cells by fitness, with
    /// optional uniqueness (`distinctCells = true`) to avoid over-seeding
    /// from one neighbourhood. Mutating the returned genomes is safe —
    /// they're value copies of the archived entries.
    func sampleSeeds(count: Int, distinctCells: Bool = true, rng: GARandom) -> [ScheduleChromosome] {
        lock.lock()
        let snapshot = cells
        lock.unlock()
        guard !snapshot.isEmpty, count > 0 else { return [] }

        let sorted = snapshot
            .map { (key: $0.key, chromo: $0.value) }
            .sorted { $0.chromo.rawFitness > $1.chromo.rawFitness }

        if !distinctCells {
            return Array(sorted.prefix(count).map(\.chromo))
        }

        // distinctCells = true is the default; top-K already comes from
        // distinct keys because `cells` is a dictionary. The explicit
        // flag exists to document intent and to allow future multi-archive
        // layouts to pick from the same cell twice with different
        // descriptors.
        let chosen = sorted.prefix(count).map(\.chromo)
        return Array(chosen)
    }

    /// Complete set of elites for callers that want to render the QD
    /// frontier as a grid or surface.
    var allElites: [ScheduleChromosome] {
        lock.lock(); defer { lock.unlock() }
        return Array(cells.values)
    }

    /// Cell coverage: fraction of the grid populated. 0 = empty, 1 =
    /// every (res^4) cell has an elite.
    var coverage: Double {
        lock.lock(); defer { lock.unlock() }
        let total = Double(resolution * resolution * resolution * resolution)
        return Double(cells.count) / total
    }

    /// Drop all entries; reuse for tests / repeated runs.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        cells.removeAll(keepingCapacity: true)
    }
}
