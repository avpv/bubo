import Foundation

// MARK: - Linkage Tree Genetic Algorithm (LTGA)
//
// Captures which genes tend to co-vary in successful schedules and uses
// that structure to produce dependency-aware crossovers. Traditional
// crossover operators (single-point, two-point, uniform) pick their
// recombination unit arbitrarily — genes next to each other in the
// chromosome are no more "linked" than genes far apart. For scheduling
// that's a clear mismatch: genes for dependent tasks, or tasks sharing a
// morning/afternoon, carry real co-adaptation that positional crossover
// shreds every call.
//
// LTGA instead learns the linkage structure from the current population,
// then crosses over in units drawn from that structure. The learned
// units are the internal nodes of a hierarchical linkage tree built by
// UPGMA clustering on pairwise mutual information of gene placements.
//
// This implementation stays deliberately light:
//   • MI is computed over *day bins* rather than minute-level positions
//     (genes on the same day are "similar" enough for building blocks).
//   • The tree is rebuilt every `rebuildInterval` generations, not every
//     generation, so the cost amortizes.
//   • Group sampling returns uniform over non-trivial internal nodes
//     (size 2..N-1); leaves and the root are skipped because
//     copying a leaf is a no-op and copying the root is a full
//     parent swap.

// MARK: - Linkage Tree

struct LinkageTree: Sendable {
    /// Gene-index groups worth sampling during crossover. Leaves and the
    /// full-genome root are excluded — neither produces a useful
    /// crossover unit.
    let groups: [[Int]]
    /// Number of genes the tree was built for. Used as a sanity check at
    /// crossover time; a mismatch falls back to a safe operator.
    let geneCount: Int

    var isUsable: Bool { !groups.isEmpty && geneCount > 1 }
}

// MARK: - Linkage Model

/// Thread-safe reference-typed holder for the current linkage tree.
/// Lives on `OptimizerContext` so every island shares the same learned
/// structure — the population is pooled across islands at update time
/// which gives the MI estimator more samples and less variance.
///
/// Exactly one `LinkageModel` is constructed per optimization run. The
/// GA loop calls `rebuildIfNeeded` every generation; the model decides
/// whether enough generations have passed to justify the recomputation.
final class LinkageModel: @unchecked Sendable {
    /// Number of generations between tree rebuilds. 5 is the literature
    /// sweet spot: frequent enough that the model tracks population
    /// drift, cheap enough that O(N² · popSize) MI estimation doesn't
    /// dominate the generation cost.
    let rebuildInterval: Int

    /// Minimum population size before the model attempts to build a
    /// tree. Below this MI is almost pure noise (few joint samples per
    /// bucket) and the resulting tree is actively harmful.
    let minPopulationSize: Int

    private var tree: LinkageTree?
    private var lastRebuildGeneration: Int = -1_000_000
    private let lock = NSLock()

    init(rebuildInterval: Int = 5, minPopulationSize: Int = 30) {
        self.rebuildInterval = rebuildInterval
        self.minPopulationSize = minPopulationSize
    }

    // MARK: - Update

    /// Rebuild the linkage tree when due. Passing the current population
    /// and the generation number lets us skip quickly most of the time
    /// and only pay the MI cost every `rebuildInterval` generations.
    func rebuildIfNeeded(
        population: [ScheduleChromosome],
        generation: Int,
        context: OptimizerContext
    ) {
        guard population.count >= minPopulationSize else { return }
        guard generation - lastRebuildGeneration >= rebuildInterval else { return }

        let built = Self.buildTree(population: population, calendar: context.calendar)
        lock.lock()
        tree = built
        lastRebuildGeneration = generation
        lock.unlock()
    }

    /// Generic entry point used by the GA loop, which carries a
    /// `Population<C>` where `C: Chromosome`. Casts each individual to
    /// `ScheduleChromosome`; if any element isn't one (e.g. the
    /// permutation chromosome in Pomodoro sequencing), we silently
    /// short-circuit so LTGA doesn't fight with other genome types.
    func rebuildIfNeeded<C: Chromosome>(
        from individuals: [C],
        generation: Int,
        context: OptimizerContext
    ) {
        var schedules: [ScheduleChromosome] = []
        schedules.reserveCapacity(individuals.count)
        for ind in individuals {
            guard let s = ind as? ScheduleChromosome else { return }
            schedules.append(s)
        }
        rebuildIfNeeded(population: schedules, generation: generation, context: context)
    }

    // MARK: - Sample

    /// Current tree, or `nil` if no tree has been built (population too
    /// small or still waiting for the first rebuild).
    var currentTree: LinkageTree? {
        lock.lock()
        defer { lock.unlock() }
        return tree
    }

    /// Sample a random non-trivial group from the current tree. Returns
    /// `nil` when the tree isn't yet usable — callers should fall back
    /// to a safer crossover operator in that case.
    func sampleGroup(rng: GARandom) -> [Int]? {
        lock.lock()
        defer { lock.unlock() }
        guard let tree, tree.isUsable else { return nil }
        return rng.pick(tree.groups)
    }

    // MARK: - Tree Construction (UPGMA over MI distance)

    /// Build a linkage tree from the current population. Returns a tree
    /// with internal-node gene groups ready for crossover, or `nil` if
    /// the population is degenerate (all identical genes — no MI signal).
    private static func buildTree(
        population: [ScheduleChromosome],
        calendar: Calendar
    ) -> LinkageTree? {
        guard let first = population.first else { return nil }
        let n = first.genes.count
        guard n >= 2 else {
            return LinkageTree(groups: [], geneCount: n)
        }
        // All chromosomes in this run are over the same event set, so
        // `n` is stable across the population. Paranoid guard anyway.
        for chrom in population where chrom.genes.count != n {
            return nil
        }

        // Discretize each gene's placement into a "day index" within the
        // horizon span of the population. We use the min/max day across
        // the whole pool to produce a compact per-gene histogram — more
        // bins than days observed would create sparse joint tables and
        // hurt MI estimates.
        let dayIndices = encodeAsDayIndices(population: population, calendar: calendar)

        // Pairwise MI matrix. Symmetric, zero diagonal.
        let mi = mutualInformationMatrix(dayIndices: dayIndices, geneCount: n)

        // Distance for UPGMA: d = max(0, maxMI - MI). Higher MI → closer.
        // Using max-based rescaling keeps distances non-negative even when
        // MI estimates dip slightly below zero for small samples.
        let maxMI = mi.flatMap { $0 }.max() ?? 1.0
        let normalizer = maxMI > 1e-9 ? maxMI : 1.0

        // Active clusters start as singletons {0}, {1}, …
        var clusters: [[Int]] = (0..<n).map { [$0] }
        var distances = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n where i != j {
                distances[i][j] = max(0, normalizer - mi[i][j])
            }
        }
        var alive = Set(0..<n)
        var groups: [[Int]] = []

        // UPGMA-style merging: repeatedly fuse the closest pair, record
        // the merged cluster as a candidate crossover group, and collapse
        // distances via average linkage. O(n³) worst-case, but n is
        // typically ≤ 30 so this is negligible.
        while alive.count > 1 {
            var bestI = -1, bestJ = -1
            var bestDist = Double.infinity
            let aliveArr = Array(alive).sorted()
            for (idx, i) in aliveArr.enumerated() {
                for j in aliveArr[(idx + 1)...] {
                    if distances[i][j] < bestDist {
                        bestDist = distances[i][j]
                        bestI = i
                        bestJ = j
                    }
                }
            }
            if bestI < 0 || bestJ < 0 { break }

            // Merge cluster j into cluster i, remove j.
            let merged = clusters[bestI] + clusters[bestJ]
            clusters[bestI] = merged
            alive.remove(bestJ)

            // Update distances: average linkage between merged cluster
            // and each remaining cluster.
            for k in alive where k != bestI {
                let newDist = (distances[bestI][k] + distances[bestJ][k]) / 2.0
                distances[bestI][k] = newDist
                distances[k][bestI] = newDist
            }

            // Record every non-trivial internal cluster as a candidate
            // crossover group. Leaves (size 1) are copied verbatim when
            // no crossover happens; full-root (size n) is a parent swap
            // that the GA already does elsewhere.
            if merged.count >= 2 && merged.count < n {
                groups.append(merged.sorted())
            }
        }

        return LinkageTree(groups: groups, geneCount: n)
    }

    /// Represent each chromosome as an array of day indices (0-based
    /// within the observed range). Excluded genes get index `-1`, which
    /// becomes its own MI bucket and lets the model pick up linkage
    /// between droppable tasks.
    private static func encodeAsDayIndices(
        population: [ScheduleChromosome],
        calendar: Calendar
    ) -> [[Int]] {
        // Find the global min day across the population so every
        // chromosome's day indices are comparable.
        var earliest: Date?
        for chrom in population {
            for gene in chrom.genes where gene.isIncluded {
                let day = calendar.startOfDay(for: gene.startTime)
                if earliest == nil || day < earliest! {
                    earliest = day
                }
            }
        }
        guard let earliest else {
            return population.map { chrom in [Int](repeating: -1, count: chrom.genes.count) }
        }

        return population.map { chrom -> [Int] in
            chrom.genes.map { gene -> Int in
                guard gene.isIncluded else { return -1 }
                let day = calendar.startOfDay(for: gene.startTime)
                let diff = calendar.dateComponents([.day], from: earliest, to: day).day ?? 0
                return max(0, diff)
            }
        }
    }

    /// Pairwise mutual information between every gene pair across the
    /// population's day-index encoding. Empirical plug-in estimator with
    /// Laplace smoothing (add-one) so zero-count pairs don't produce
    /// negative infinities under log.
    ///
    /// Complexity: O(n² · popSize). At n=30, popSize=200 that's 180k ops
    /// per rebuild, every 5 generations — well under 1% of generation
    /// cost.
    private static func mutualInformationMatrix(
        dayIndices: [[Int]],
        geneCount n: Int
    ) -> [[Double]] {
        let pop = dayIndices.count
        guard pop > 1 else {
            return [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        }

        // Discover the actual set of distinct labels (day indices + the
        // excluded sentinel). Tiny — usually ≤ 8 values for a weekly
        // horizon — so a simple array works fine.
        var labelSet = Set<Int>()
        for row in dayIndices {
            for v in row { labelSet.insert(v) }
        }
        let labels = Array(labelSet).sorted()
        let labelIndex = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($1, $0) })
        let k = labels.count
        guard k >= 2 else {
            return [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        }

        // Marginal per-gene histograms.
        var marginals = [[Double]](repeating: [Double](repeating: 0, count: k), count: n)
        for row in dayIndices {
            for i in 0..<n {
                if let bin = labelIndex[row[i]] {
                    marginals[i][bin] += 1
                }
            }
        }
        let denom = Double(pop) + Double(k)
        for i in 0..<n {
            for b in 0..<k {
                marginals[i][b] = (marginals[i][b] + 1.0) / denom
            }
        }

        // Pairwise MI via joint histograms.
        var mi = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                var joint = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
                for row in dayIndices {
                    guard let a = labelIndex[row[i]], let b = labelIndex[row[j]] else { continue }
                    joint[a][b] += 1
                }
                let jDenom = Double(pop) + Double(k * k)
                var miValue = 0.0
                for a in 0..<k {
                    for b in 0..<k {
                        let pij = (joint[a][b] + 1.0) / jDenom
                        let pi = marginals[i][a]
                        let pj = marginals[j][b]
                        if pij > 1e-12 && pi > 1e-12 && pj > 1e-12 {
                            miValue += pij * log(pij / (pi * pj))
                        }
                    }
                }
                mi[i][j] = miValue
                mi[j][i] = miValue
            }
        }
        return mi
    }
}
