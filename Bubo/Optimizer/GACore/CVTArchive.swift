import Foundation

// MARK: - Centroidal Voronoi Tessellation Archive

/// QD archive that partitions behaviour space into K Voronoi cells
/// whose centroids are refined by Lloyd's algorithm on a sample of
/// real behaviour descriptors. Strictly more expressive than a fixed
/// grid: cells concentrate where descriptors actually land (rare
/// behaviours still get their own cell, dense regions split into
/// many) rather than wasting a quarter of the grid on empty corners.
///
/// Classical CVT-MAP-Elites (Vassiliades et al. 2016, with 2024
/// refinements using adaptive K in Pugh et al.) runs Lloyd's once on
/// a random sample upfront, then keeps the centroids frozen for the
/// rest of the run. That's what we do here — adapting centroids
/// mid-run would invalidate the per-cell elite contracts.
///
/// Thread safety: single NSLock around the cell table. The centroid
/// array is immutable after `initialize`.
final class CVTArchive: @unchecked Sendable {
    private var centroids: [BehaviorDescriptor] = []
    private var cells: [Int: ScheduleChromosome] = [:]
    private let lock = NSLock()

    /// Target number of Voronoi cells. Defaults to 128 — a good
    /// balance between coverage resolution and per-cell occupancy.
    let targetK: Int

    /// Lloyd's algorithm iteration cap. 50 iterations are enough to
    /// converge on typical samples; we early-exit when centroid drift
    /// falls below `convergenceEpsilon`.
    let maxLloydIterations: Int

    /// Convergence threshold for Lloyd's algorithm, measured as the
    /// maximum per-centroid movement in descriptor space.
    let convergenceEpsilon: Double = 1e-4

    init(targetK: Int = 128, maxLloydIterations: Int = 50) {
        self.targetK = max(4, targetK)
        self.maxLloydIterations = maxLloydIterations
    }

    // MARK: - Initialization

    /// Seed the Voronoi tessellation from a sample of real behaviour
    /// descriptors. Pass at least `10 × targetK` samples — Lloyd's
    /// tends to degenerate (empty cells, stale centroids) on sparser
    /// inputs, and we skip the initialisation entirely when the
    /// sample is too small, falling back to a uniform grid.
    ///
    /// Once initialised the centroids are frozen for the rest of the
    /// archive's life; call `reset()` to re-initialise with a new
    /// sample if the workload shifts significantly.
    func initialize(sample: [BehaviorDescriptor], rng: GARandom) {
        lock.lock()
        defer { lock.unlock() }
        guard sample.count >= max(targetK * 2, 16) else {
            // Not enough data — fall back to the uniform cube
            // placement so the archive is still usable, just with
            // worse coverage than a proper CVT would give.
            centroids = uniformCubeCentroids()
            cells.removeAll()
            return
        }

        // Start with K random samples from the input as seed
        // centroids — a common Lloyd's initialisation variant that
        // avoids pathological tight clusters the pure-random
        // alternative produces.
        var shuffled = rng.shuffled(sample)
        centroids = Array(shuffled.prefix(targetK))
        // Lloyd's iterations.
        for _ in 0..<maxLloydIterations {
            var clusters: [[BehaviorDescriptor]] = Array(repeating: [], count: centroids.count)
            for point in sample {
                let idx = nearestCentroidIndex(point)
                clusters[idx].append(point)
            }
            var newCentroids: [BehaviorDescriptor] = []
            newCentroids.reserveCapacity(centroids.count)
            var maxShift = 0.0
            for (i, cluster) in clusters.enumerated() {
                if cluster.isEmpty {
                    // Empty cells stick with their old centroid —
                    // Lloyd's can sometimes starve a centroid when
                    // another one is "stealing" its volume; keeping
                    // the old position lets the cell stay nominally
                    // reachable.
                    newCentroids.append(centroids[i])
                    continue
                }
                let mean = meanDescriptor(of: cluster)
                maxShift = max(maxShift, centroids[i].distance(to: mean))
                newCentroids.append(mean)
            }
            centroids = newCentroids
            if maxShift < convergenceEpsilon { break }
        }
        cells.removeAll()
    }

    /// Mean descriptor — component-wise average. Kept tiny and inline
    /// to avoid dragging in `Accelerate` for a 4-D mean.
    private func meanDescriptor(of cluster: [BehaviorDescriptor]) -> BehaviorDescriptor {
        guard !cluster.isEmpty else {
            return BehaviorDescriptor(focusFraction: 0, meetingDensity: 0, energyFit: 0, contextSwitches: 0)
        }
        var a = 0.0, b = 0.0, c = 0.0, d = 0.0
        for p in cluster {
            a += p.focusFraction
            b += p.meetingDensity
            c += p.energyFit
            d += p.contextSwitches
        }
        let n = Double(cluster.count)
        return BehaviorDescriptor(
            focusFraction: a / n,
            meetingDensity: b / n,
            energyFit: c / n,
            contextSwitches: d / n
        )
    }

    /// Deterministic uniform-cube fallback when Lloyd's can't run.
    /// Chosen so the fall-back archive still covers the 4-D [0, 1]⁴
    /// cube roughly uniformly. K is rounded up to the nearest
    /// 4-th power ≥ targetK so each axis gets an integer subdivision.
    private func uniformCubeCentroids() -> [BehaviorDescriptor] {
        let resolution = Int(ceil(pow(Double(targetK), 1.0 / 4.0)))
        let step = 1.0 / Double(resolution)
        var result: [BehaviorDescriptor] = []
        result.reserveCapacity(resolution * resolution * resolution * resolution)
        for i in 0..<resolution {
            for j in 0..<resolution {
                for k in 0..<resolution {
                    for l in 0..<resolution {
                        result.append(BehaviorDescriptor(
                            focusFraction: (Double(i) + 0.5) * step,
                            meetingDensity: (Double(j) + 0.5) * step,
                            energyFit: (Double(k) + 0.5) * step,
                            contextSwitches: (Double(l) + 0.5) * step
                        ))
                    }
                }
            }
        }
        return result
    }

    // MARK: - Query / Admit

    /// Index of the nearest centroid to `point`. Linear scan over
    /// centroids — K is 128-ish and scan is O(K·4) per call.
    private func nearestCentroidIndex(_ point: BehaviorDescriptor) -> Int {
        var bestIdx = 0
        var bestDist = Double.infinity
        for (i, c) in centroids.enumerated() {
            let d = c.distance(to: point)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        return bestIdx
    }

    /// Try to admit a chromosome against its Voronoi cell. Returns
    /// the cell index so telemetry can log coverage increases.
    @discardableResult
    func admit(_ chromosome: ScheduleChromosome, descriptor: BehaviorDescriptor) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !centroids.isEmpty else { return -1 }
        let idx = nearestCentroidIndex(descriptor)
        if let incumbent = cells[idx] {
            if chromosome.rawFitness > incumbent.rawFitness {
                cells[idx] = chromosome
            }
        } else {
            cells[idx] = chromosome
        }
        return idx
    }

    /// All current elites, for warm-start and UI surfaces.
    var allElites: [ScheduleChromosome] {
        lock.lock(); defer { lock.unlock() }
        return Array(cells.values)
    }

    /// Coverage = filled cells / centroid count.
    var coverage: Double {
        lock.lock(); defer { lock.unlock() }
        return centroids.isEmpty ? 0 : Double(cells.count) / Double(centroids.count)
    }

    /// Find the archive elite closest in descriptor space to the
    /// query. Mirrors `MAPElitesArchive.nearest` so callers can
    /// swap archive backends without rewriting reoptimisation
    /// logic.
    func nearest(to target: BehaviorDescriptor, context: OptimizerContext) -> ScheduleChromosome? {
        lock.lock()
        let snapshot = cells
        lock.unlock()
        guard !snapshot.isEmpty else { return nil }
        var bestChromo: ScheduleChromosome?
        var bestDist = Double.infinity
        for (_, elite) in snapshot {
            let d = BehaviorDescriptor(chromosome: elite, context: context).distance(to: target)
            if d < bestDist {
                bestDist = d
                bestChromo = elite
            }
        }
        return bestChromo
    }

    /// Throw away every cell and every learned centroid. Used by the
    /// app when workloads change enough that the old tessellation is
    /// stale.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        centroids.removeAll()
        cells.removeAll()
    }
}
