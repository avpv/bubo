import Foundation

// MARK: - Behavior Descriptor

/// A compact, low-dimensional summary of a chromosome's *behaviour* in
/// objective-relevant terms: not the fitness value itself, but the
/// structural fingerprint the user would perceive. Two schedules with
/// identical behaviour descriptors look functionally the same — similar
/// focus fraction, similar meeting density, similar energy-fit. Two that
/// differ are meaningfully different experiences.
///
/// Used by `NoveltyArchive` (pure novelty search) and `MAPElitesArchive`
/// (quality-diversity). Kept small on purpose: k-NN novelty and CVT cells
/// both work best in 3-5 dimensions, more than that and the space becomes
/// sparse enough that the novelty metric loses signal.
///
/// All components are normalised to [0, 1] so Euclidean distance in
/// descriptor space has the same scale as the GA's genotypic distance.
struct BehaviorDescriptor: Hashable, Sendable {
    /// Fraction of scheduled duration that is focus/deep-work blocks.
    /// 0 = no focus time, 1 = entire schedule is focus.
    let focusFraction: Double

    /// Meeting density: meetings per working hour. Clamped to [0, 1] by
    /// dividing against an upper reference (two meetings per hour ≈ 1.0).
    let meetingDensity: Double

    /// Mean energy-fit across included genes: how well each gene lands on
    /// its event's preferred hour band, averaged and normalised.
    let energyFit: Double

    /// Context-switch fraction: number of adjacent gene pairs whose
    /// `context` tag differs, divided by the number of pairs. Higher =
    /// more thrash; lower = more batched work.
    let contextSwitches: Double

    /// Build descriptor from the chromosome's active genes. Uses only
    /// gene-local fields so no fitness evaluation is needed — this keeps
    /// the archive cheap to populate even on offspring we're about to
    /// evaluate.
    init(chromosome: ScheduleChromosome, context: OptimizerContext) {
        let active = chromosome.genes.filter { $0.isIncluded }
        let totalDur = active.reduce(0.0) { $0 + $1.duration }

        // Focus fraction: focus-block genes over total scheduled minutes.
        if totalDur > 0 {
            let focusDur = active.filter(\.isFocusBlock).reduce(0.0) { $0 + $1.duration }
            self.focusFraction = min(1.0, focusDur / totalDur)
        } else {
            self.focusFraction = 0
        }

        // Meeting density: non-focus, non-droppable events treated as
        // meetings. Normalised against (2 meetings/hour) × horizon hours.
        let meetings = active.filter { !$0.isFocusBlock && $0.storyPoints == nil }.count
        let horizonHours = max(1.0, context.planningHorizon.duration / 3600.0)
        self.meetingDensity = min(1.0, Double(meetings) / (horizonHours * 2.0))

        // Energy fit: gene lands in its preferredHourRange iff applicable.
        // Genes without a preference contribute 1 (neutral).
        let cal = context.calendar
        var fitSum = 0.0
        var fitCount = 0
        for gene in active {
            fitCount += 1
            let hour = cal.component(.hour, from: gene.startTime)
            if let event = context.movableEvents.first(where: { $0.id == gene.eventId }),
               let preferred = event.preferredHourRange {
                fitSum += preferred.contains(hour) ? 1.0 : 0.0
            } else {
                fitSum += 1.0
            }
        }
        self.energyFit = fitCount > 0 ? fitSum / Double(fitCount) : 1.0

        // Context switches: sort active genes by start time, count adjacent
        // pairs with differing context tags. Droppable tasks without a tag
        // are treated as their own "null" context.
        let ordered = active.sorted { $0.startTime < $1.startTime }
        guard ordered.count >= 2 else {
            self.contextSwitches = 0
            return
        }
        var switches = 0
        for i in 1..<ordered.count {
            if ordered[i].context != ordered[i - 1].context {
                switches += 1
            }
        }
        self.contextSwitches = Double(switches) / Double(ordered.count - 1)
    }

    /// Manual init for tests and archive-seeding paths.
    init(
        focusFraction: Double,
        meetingDensity: Double,
        energyFit: Double,
        contextSwitches: Double
    ) {
        self.focusFraction = focusFraction
        self.meetingDensity = meetingDensity
        self.energyFit = energyFit
        self.contextSwitches = contextSwitches
    }

    /// Euclidean distance in the normalised 4-D descriptor space. Never
    /// exceeds 2.0 because every component is clamped to [0, 1].
    func distance(to other: BehaviorDescriptor) -> Double {
        let dA = focusFraction - other.focusFraction
        let dB = meetingDensity - other.meetingDensity
        let dC = energyFit - other.energyFit
        let dD = contextSwitches - other.contextSwitches
        return (dA * dA + dB * dB + dC * dC + dD * dD).squareRoot()
    }
}

// MARK: - Novelty Archive

/// Append-only archive of behaviour descriptors used to compute a novelty
/// score for any candidate chromosome. Classical Lehman & Stanley novelty
/// search: an individual's novelty = average distance to its k nearest
/// neighbours in the archive + current population. Schedules that end up
/// in sparse regions of behaviour space get a high novelty score even
/// when their raw fitness is mediocre, which is how the GA escapes
/// deceptive local optima (e.g. "all focus blocks front-loaded" might be
/// low-fitness but its rarity drives exploration of neighbouring layouts).
///
/// Combined with raw fitness through a simple weighted sum:
///     effectiveFitness = (1 - w) · rawFitness + w · novelty
/// where `w ∈ [0, 1]` is `GAConfiguration.noveltyWeight`. w=0 falls back
/// to pure fitness; w=1 is pure novelty search.
///
/// Thread safety: each island that uses novelty search gets its own
/// archive. The `IslandModelGA` passes the same instance through every
/// island's `OptimizerContext` when `GAConfiguration.enableNovelty` is
/// on, guarded by `NSLock` so concurrent island reads/writes are safe.
final class NoveltyArchive: @unchecked Sendable {
    /// Archived descriptors, capped at `maxSize` via FIFO eviction. FIFO
    /// is the canonical archive policy in the novelty-search literature —
    /// new discoveries keep pushing the frontier outward as old ones
    /// stop contributing signal.
    private var entries: [BehaviorDescriptor] = []
    private let maxSize: Int
    private let lock = NSLock()

    /// Number of nearest neighbours for the novelty score. k=15 is the
    /// reference value from Lehman & Stanley 2011. Small enough to stay
    /// local, large enough to smooth out single-outlier effects.
    let k: Int

    /// Novelty threshold: a candidate is archived only if its novelty
    /// exceeds this value. Prevents the archive from filling up with
    /// near-duplicates when the GA is exploiting a cluster.
    let archiveThreshold: Double

    init(k: Int = 15, maxSize: Int = 1000, archiveThreshold: Double = 0.05) {
        self.k = k
        self.maxSize = maxSize
        self.archiveThreshold = archiveThreshold
    }

    /// Compute the novelty score for `descriptor` as the mean distance to
    /// its k nearest neighbours in `archived + peers`. Returns 1.0 when
    /// both collections are empty (nothing to compare against, so anything
    /// is maximally novel — the GA will stamp out that lead quickly).
    ///
    /// Clamped to [0, 1] so the `effectiveFitness` blend stays in the same
    /// numeric range as raw fitness.
    func novelty(of descriptor: BehaviorDescriptor, peers: [BehaviorDescriptor] = []) -> Double {
        lock.lock()
        let archived = entries
        lock.unlock()

        let combined = archived + peers
        guard !combined.isEmpty else { return 1.0 }

        // Collect all distances, pick the k smallest. Using a partial sort
        // rather than full sort avoids O(n log n) on populations that will
        // grow to the thousands when the archive saturates.
        var distances = combined.map { $0.distance(to: descriptor) }
        let neighbours = min(k, distances.count)
        // Partial sort: in-place Quickselect-style. For small archives
        // just sort fully — cheaper than manual partitioning.
        distances.sort()
        let sum = distances.prefix(neighbours).reduce(0, +)
        let mean = sum / Double(neighbours)
        // Normalise by max possible 4-D distance (2.0) and clamp.
        return min(1.0, mean / 2.0)
    }

    /// Consider adding `descriptor` to the archive. Adds when the novelty
    /// score exceeds `archiveThreshold` — otherwise the descriptor is
    /// already well represented. Evicts the oldest entry when full.
    @discardableResult
    func admit(_ descriptor: BehaviorDescriptor, peers: [BehaviorDescriptor] = []) -> Bool {
        let score = novelty(of: descriptor, peers: peers)
        guard score >= archiveThreshold else { return false }
        lock.lock()
        defer { lock.unlock() }
        if entries.count >= maxSize {
            entries.removeFirst()
        }
        entries.append(descriptor)
        return true
    }

    /// Snapshot of the archive for tests and telemetry.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Drop all entries. For test fixtures and repeated-run harnesses.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
    }
}
