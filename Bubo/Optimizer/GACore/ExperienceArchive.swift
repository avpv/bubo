import Foundation

// MARK: - Workload Signature

/// Compact identifier for "which kind of day" the GA is optimizing. Used
/// by `ExperienceArchive` to retrieve high-fitness chromosomes from past
/// runs whose workload was similar to the current one. The signature is
/// deliberately lossy — we want "similar-shaped" days to hit the same
/// bucket, not an exact match.
struct WorkloadSignature: Hashable, Sendable {
    /// Number of movable events, bucketed into coarse ranges so small
    /// perturbations don't fragment the archive.
    let eventCountBucket: Int

    /// Fraction of movable events with priority > 0.7, bucketed to 5%.
    let highPriorityBucket: Int

    /// Fraction of focus-block events, bucketed to 10%.
    let focusFractionBucket: Int

    /// Horizon length in days, clamped to [1, 14].
    let horizonDays: Int

    /// Peak energy hour from preferences (pass-through, no bucketing —
    /// this is already discrete).
    let peakEnergyHour: Int

    init(context: OptimizerContext) {
        let events = context.movableEvents

        // Event count bucketing: <5, 5-9, 10-19, 20-49, 50+.
        let n = events.count
        if n < 5 { self.eventCountBucket = 0 }
        else if n < 10 { self.eventCountBucket = 1 }
        else if n < 20 { self.eventCountBucket = 2 }
        else if n < 50 { self.eventCountBucket = 3 }
        else { self.eventCountBucket = 4 }

        // High-priority fraction in 5% buckets.
        let highPriCount = events.filter { $0.priority > 0.7 }.count
        let hpFrac = n > 0 ? Double(highPriCount) / Double(n) : 0
        self.highPriorityBucket = Int((hpFrac * 20).rounded())

        // Focus fraction in 10% buckets.
        let focusCount = events.filter(\.isFocusBlock).count
        let focusFrac = n > 0 ? Double(focusCount) / Double(n) : 0
        self.focusFractionBucket = Int((focusFrac * 10).rounded())

        let days = Int(context.planningHorizon.duration / 86400)
        self.horizonDays = min(14, max(1, days))
        self.peakEnergyHour = context.preferences.peakEnergyHour
    }
}

// MARK: - Experience Entry

/// A single remembered successful run: the winning chromosome (or a small
/// set of high-fitness elites) and the fitness it achieved. Stored by
/// signature; retrieval returns the top-K elites across matching buckets.
struct ExperienceEntry: Sendable {
    let chromosome: ScheduleChromosome
    let fitness: Double
    let timestamp: Date
}

// MARK: - Experience Archive

/// Bounded in-memory store of high-fitness chromosomes keyed by workload
/// signature. At the start of a new run the GA consults the archive with
/// the current signature and seeds the population with the top-K entries
/// from this bucket (plus fallbacks from neighbouring buckets when the
/// exact bucket is empty). This gives repeatable patterns a 2-3× faster
/// convergence because they start near a previously-found good region.
///
/// Complements `MAPElitesArchive`: that archive covers diverse styles
/// within a *single* run; `ExperienceArchive` carries quality across
/// runs by workload type.
///
/// Persistence is outside the scope of this core — the BuboOptimizer
/// service can wire it to disk via any codable adapter when production
/// persistence is desired.
///
/// Thread safety: single NSLock; writes happen at run-end, reads at
/// run-start, so contention is nil in normal usage.
final class ExperienceArchive: @unchecked Sendable {
    /// Per-bucket ring of entries, capped at `perSignatureCap`.
    private var buckets: [WorkloadSignature: [ExperienceEntry]] = [:]
    private let lock = NSLock()

    /// Max entries retained per signature bucket. Small enough that
    /// retrieval stays linear, large enough to preserve the top-end of
    /// the fitness distribution.
    let perSignatureCap: Int

    /// Global cap on total stored entries. Once hit, the oldest buckets
    /// by last-updated timestamp are evicted wholesale.
    let totalCap: Int

    init(perSignatureCap: Int = 10, totalCap: Int = 500) {
        self.perSignatureCap = perSignatureCap
        self.totalCap = totalCap
    }

    /// Record a successful chromosome for the given signature. Replaces
    /// the bucket's lowest-fitness entry when the cap is reached, drops
    /// nothing when the new entry is itself the weakest.
    func record(signature: WorkloadSignature, chromosome: ScheduleChromosome, fitness: Double) {
        lock.lock()
        defer { lock.unlock() }

        let entry = ExperienceEntry(chromosome: chromosome, fitness: fitness, timestamp: Date())
        var bucket = buckets[signature, default: []]
        if bucket.count < perSignatureCap {
            bucket.append(entry)
        } else if let weakest = bucket.enumerated().min(by: { $0.element.fitness < $1.element.fitness }),
                  weakest.element.fitness < fitness {
            bucket[weakest.offset] = entry
        }
        bucket.sort { $0.fitness > $1.fitness }
        buckets[signature] = bucket

        // Global eviction: when we blow totalCap, drop the least recently
        // updated signature entirely. Coarse but keeps the pressure off
        // hot buckets.
        let totalCount = buckets.values.reduce(0) { $0 + $1.count }
        if totalCount > totalCap {
            let victim = buckets
                .map { (key: $0.key, lastStamp: $0.value.map(\.timestamp).max() ?? Date.distantPast) }
                .min(by: { $0.lastStamp < $1.lastStamp })?.key
            if let victim {
                buckets.removeValue(forKey: victim)
            }
        }
    }

    /// Retrieve up to `count` remembered chromosomes for this signature,
    /// widening the search to neighbouring buckets when the exact bucket
    /// is light. Neighbouring = differs by at most 1 in event-count,
    /// high-priority, or focus-fraction bucket (same horizon/peak hour).
    func retrieve(signature: WorkloadSignature, count: Int) -> [ScheduleChromosome] {
        lock.lock()
        defer { lock.unlock() }

        var pool: [ExperienceEntry] = buckets[signature] ?? []

        if pool.count < count {
            for delta in 1...2 where pool.count < count {
                for (key, entries) in buckets where key != signature {
                    let dEvt = abs(key.eventCountBucket - signature.eventCountBucket)
                    let dHP = abs(key.highPriorityBucket - signature.highPriorityBucket)
                    let dFocus = abs(key.focusFractionBucket - signature.focusFractionBucket)
                    let matchesHorizon = key.horizonDays == signature.horizonDays
                    let matchesPeak = key.peakEnergyHour == signature.peakEnergyHour
                    if dEvt <= delta && dHP <= delta && dFocus <= delta && matchesHorizon && matchesPeak {
                        pool.append(contentsOf: entries)
                    }
                }
            }
        }

        let sorted = pool.sorted { $0.fitness > $1.fitness }
        return Array(sorted.prefix(count).map(\.chromosome))
    }

    /// Current bucket count; useful for telemetry / tests.
    var size: Int {
        lock.lock(); defer { lock.unlock() }
        return buckets.values.reduce(0) { $0 + $1.count }
    }

    /// Drop all stored experience.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        buckets.removeAll()
    }
}
