import Foundation

// MARK: - Surrogate Filter
//
// Cheap k-nearest-neighbour surrogate for offspring fitness. The GA loop
// generates more offspring than it evaluates, asks the surrogate to
// predict every candidate's fitness, and runs the expensive evaluator
// only on the top-K predicted survivors. The remaining offspring are
// discarded before paying the evaluator cost.
//
// Why kNN and not a neural net: the real evaluator runs in ~0.1–1 ms on
// this workload. A neural net inference pass at any interesting depth
// would eat the budget it saves. kNN over ≤200 recent evaluations is
// O(k·N·d) per prediction where d = gene count — tens of microseconds,
// well under the full-evaluator cost.
//
// Caveats (flagged in Phase 3 design discussion):
//   • On cheap evaluators the surrogate's predict cost approaches the
//     evaluator's eval cost; net speedup shrinks toward zero. The GA
//     caller controls `overgenerationFactor` so this can be tuned down
//     or off.
//   • kNN fitness prediction is only accurate in regions of the search
//     space the archive has sampled. Freshly-mutated offspring that fall
//     into unseen regions receive noisy predictions and may be wrongly
//     culled. The archive is large (200 entries default) and updated
//     every evaluation so coverage grows with population diversity.
//
// Thread safety: the filter is shared across offspring (sequential access
// per generation) and across islands (parallel access when several
// islands evaluate concurrently). Reads and writes go through NSLock —
// contention is negligible because prediction is the hot path and
// lookups are read-only over a dictionary snapshot.

final class SurrogateFilter: @unchecked Sendable {
    /// Training entries — genes paired with a recently-observed fitness.
    /// Capped at `archiveCapacity` to bound prediction cost; oldest
    /// entries are evicted FIFO.
    private struct Entry {
        let genes: [ScheduleGene]
        let fitness: Double
    }

    /// Max samples kept in the training archive. 200 balances prediction
    /// accuracy (more = smoother estimates in well-covered regions)
    /// against per-prediction cost (O(N·d) kNN scan).
    let archiveCapacity: Int

    /// Number of nearest neighbours blended into the prediction. 5 is
    /// the literature default for kNN regression on noisy targets; fewer
    /// neighbours react faster to landscape shifts but are more variance-
    /// prone.
    let kNeighbours: Int

    /// How many offspring to generate per slot the caller actually wants
    /// to keep. 2.0 means "generate 2N, evaluate the best N predicted"
    /// — the most common practical ratio. 1.0 disables filtering.
    let overgenerationFactor: Double

    private var archive: [Entry] = []
    private let lock = NSLock()

    init(
        archiveCapacity: Int = 200,
        kNeighbours: Int = 5,
        overgenerationFactor: Double = 2.0
    ) {
        precondition(archiveCapacity > 0)
        precondition(kNeighbours > 0)
        precondition(overgenerationFactor >= 1.0, "overgeneration must be >= 1.0")
        self.archiveCapacity = archiveCapacity
        self.kNeighbours = kNeighbours
        self.overgenerationFactor = overgenerationFactor
    }

    /// Enabled predicate — callers can skip the filter-aware code path
    /// when `overgenerationFactor == 1.0` (no culling).
    var isActive: Bool { overgenerationFactor > 1.0 + 1e-9 }

    // MARK: - Record

    /// Update the training archive with a newly-evaluated chromosome.
    /// Called by the GA loop once an evaluation returns. The genes are
    /// captured as a flat copy so subsequent in-place mutation of the
    /// caller's chromosome doesn't corrupt our training signal.
    func record(genes: [ScheduleGene], fitness: Double) {
        guard !genes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        archive.append(Entry(genes: genes, fitness: fitness))
        if archive.count > archiveCapacity {
            // FIFO eviction — simple, deterministic, keeps the recent
            // landscape in view. Swift arrays are O(1) at the head when
            // we slice to `suffix` so this stays cheap even at capacity.
            archive = Array(archive.suffix(archiveCapacity))
        }
    }

    /// Bulk warm-up seeding for situations where we already have an
    /// evaluated population (e.g. after the initial population's first
    /// sweep). Saves the per-call lock overhead.
    func bulkRecord(_ pairs: [(genes: [ScheduleGene], fitness: Double)]) {
        guard !pairs.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for pair in pairs {
            archive.append(Entry(genes: pair.genes, fitness: pair.fitness))
        }
        if archive.count > archiveCapacity {
            archive = Array(archive.suffix(archiveCapacity))
        }
    }

    // MARK: - Predict

    /// Estimate fitness for a chromosome we haven't evaluated yet. Uses
    /// inverse-distance-weighted kNN over the archive. Returns `nil`
    /// when the archive is empty (caller must treat candidate as
    /// "unknown" and evaluate it directly).
    ///
    /// Distance metric is the same SIMD-accelerated `distance(to:)` the
    /// rest of the GA uses, so two chromosomes considered close by every
    /// other subsystem remain close here.
    func predictFitness(for candidate: ScheduleChromosome) -> Double? {
        lock.lock()
        let snapshot = archive  // copy-on-read: tiny, amortizes
        lock.unlock()
        guard !snapshot.isEmpty else { return nil }

        // Per-entry distance. ScheduleChromosome.distance operates on
        // another ScheduleChromosome so we wrap each entry in a shim.
        // Building the shim every call is cheap — it just shares the
        // `genes` array by value (struct with an Array inside; copy-on-
        // write makes it O(1) until a mutation).
        struct NeighbourDistance { let fitness: Double; let dist: Double }
        var scored: [NeighbourDistance] = []
        scored.reserveCapacity(snapshot.count)
        for entry in snapshot {
            let shim = ScheduleChromosome(genes: entry.genes, needsEvaluation: false)
            let d = candidate.distance(to: shim)
            scored.append(NeighbourDistance(fitness: entry.fitness, dist: d))
        }
        scored.sort { $0.dist < $1.dist }

        let k = min(kNeighbours, scored.count)
        let neighbours = scored.prefix(k)

        // If the nearest neighbour is effectively identical, return its
        // fitness directly — kNN weighting would divide by ~0 otherwise.
        if let closest = neighbours.first, closest.dist < 1e-6 {
            return closest.fitness
        }

        // Inverse-distance weighting. Add `1e-6` to every distance to
        // avoid division spikes for very close neighbours and to keep
        // the formula numerically stable when two entries collide.
        var weightedSum = 0.0
        var weightSum = 0.0
        for n in neighbours {
            let w = 1.0 / (n.dist + 1e-6)
            weightedSum += w * n.fitness
            weightSum += w
        }
        guard weightSum > 0 else { return nil }
        return weightedSum / weightSum
    }

    // MARK: - Rank & Trim

    /// Given an over-generated offspring batch, return the indices the
    /// caller should actually evaluate — the top `N` by predicted
    /// fitness, where `N = count / overgenerationFactor`.
    ///
    /// When the archive has too few entries to support reliable
    /// prediction (< `kNeighbours`), all candidates are returned so the
    /// caller can bootstrap the archive with real evaluations.
    func rankAndSelect(
        _ offspring: [ScheduleChromosome],
        targetCount: Int
    ) -> [Int] {
        guard isActive, offspring.count > targetCount else {
            return Array(0..<offspring.count)
        }
        lock.lock()
        let archiveSize = archive.count
        lock.unlock()
        guard archiveSize >= kNeighbours else {
            return Array(0..<offspring.count)
        }

        var scored: [(index: Int, score: Double)] = []
        scored.reserveCapacity(offspring.count)
        for (i, chrom) in offspring.enumerated() {
            let predicted = predictFitness(for: chrom) ?? 0
            scored.append((i, predicted))
        }
        scored.sort { $0.score > $1.score }
        return scored.prefix(targetCount).map(\.index)
    }

    // MARK: - Telemetry

    var archiveSize: Int {
        lock.lock()
        defer { lock.unlock() }
        return archive.count
    }
}
