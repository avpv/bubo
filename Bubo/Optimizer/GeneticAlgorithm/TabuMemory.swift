import Foundation

// MARK: - Tabu Memory (Wave 1 / item 14)
//
// Glover-style tabu memory with short-term (recency) and long-term
// (frequency) components. Plugs on top of the existing ALNS/LNS loop:
// after a destroy-repair cycle moves a set of events, they're marked
// tabu for the next `tenure` steps and their frequency counter ticks.
// Operators that propose moves query the memory first — tabu moves
// are downweighted in roulette selection (soft aspiration) rather
// than hard-blocked, so genuinely better moves can still win.
//
// Long-term frequency drives diversification: an event that has been
// moved disproportionately often is kept in place and some less-
// touched event is preferred instead. Prevents the ALNS bandit from
// getting stuck cycling the same hot set of events in a basin.
//
// Thread safety: reference type with an internal lock. LNS is called
// from offspring-generation code paths that run in parallel across
// islands, so shared state needs protection. Updates are point
// reads/writes; contention is minimal because the tabu map is tiny
// (N events, typically 20-50).

/// Short-term and long-term memory for recently moved events.
final class TabuMemory: @unchecked Sendable {
    /// A move record in the short-term memory.
    struct Move: Sendable {
        /// The event the operator touched.
        let eventId: String
        /// Logical step at which the move entered the tabu list.
        let step: Int
    }

    /// Tunables. Held together for easy A/B-ing per workload.
    struct Configuration: Sendable {
        /// Number of logical steps a move stays tabu. Classical Glover
        /// recommends 7–15 for scheduling problems; we default to 10
        /// which matches the empirical sweet spot for our LNS cadence
        /// of ~30 calls per generation.
        let tenure: Int

        /// Max distinct events we keep in frequency memory. Lines up
        /// with the typical workload size (+ slack). Beyond this,
        /// stale entries evict LRU.
        let frequencyCapacity: Int

        /// Downweight applied to tabu moves in roulette selection.
        /// 0.0 = hard-block, 1.0 = no effect. Typical: 0.15, leaving
        /// meaningful but strong discouragement.
        let tabuPenalty: Double

        /// Multiplier on frequency when computing a per-event
        /// diversification bias. 0 = ignore frequency, 1 = strong
        /// steering away from over-touched events.
        let frequencyWeight: Double

        static let `default` = Configuration(
            tenure: 10,
            frequencyCapacity: 128,
            tabuPenalty: 0.15,
            frequencyWeight: 0.3
        )

        /// Stronger diversification. Use when a run shows repeated
        /// oscillation between two nearby solutions.
        static let aggressive = Configuration(
            tenure: 15,
            frequencyCapacity: 256,
            tabuPenalty: 0.05,
            frequencyWeight: 0.5
        )
    }

    let config: Configuration

    private let lock = NSLock()
    private var currentStep: Int = 0
    private var recentMoves: [Move] = []
    private var frequency: [String: Int] = [:]
    private var frequencyOrder: [String] = [] // for LRU eviction

    /// Best-seen lex fitness across the run. Used by aspiration:
    /// a tabu move that would yield a solution better than the
    /// current best is unconditionally allowed (Glover's core rule).
    private var bestHardTier: Double = -Double.infinity
    private var bestSoftTier: Double = -Double.infinity

    init(config: Configuration = .default) {
        self.config = config
    }

    // MARK: - Updates

    /// Advance the logical clock. Call once per LNS destroy-repair
    /// cycle. Clears expired tabus.
    func step() {
        lock.lock()
        defer { lock.unlock() }
        currentStep += 1
        let cutoff = currentStep - config.tenure
        if !recentMoves.isEmpty, recentMoves.first!.step <= cutoff {
            recentMoves.removeAll { $0.step <= cutoff }
        }
    }

    /// Mark a batch of events as tabu and tick their long-term
    /// frequencies. Typically called right after a destroy-repair
    /// cycle with the list of events that moved.
    func markMoves(eventIds: [String]) {
        guard !eventIds.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for id in eventIds {
            recentMoves.append(Move(eventId: id, step: currentStep))
            if frequency[id] == nil {
                frequencyOrder.append(id)
                while frequencyOrder.count > config.frequencyCapacity {
                    let evicted = frequencyOrder.removeFirst()
                    frequency.removeValue(forKey: evicted)
                }
            }
            frequency[id, default: 0] += 1
        }
    }

    /// Register the run's new best solution. Used by aspiration.
    /// Pass the lex fitness tuple, not the scalar fitness, so hard-
    /// tier gains aren't traded for soft-tier losses just to lift
    /// a tabu.
    func noteBest(hardTier: Double, softTier: Double) {
        lock.lock()
        defer { lock.unlock() }
        if hardTier > bestHardTier
            || (hardTier == bestHardTier && softTier > bestSoftTier) {
            bestHardTier = hardTier
            bestSoftTier = softTier
        }
    }

    // MARK: - Queries

    /// Is this event currently tabu?
    func isTabu(eventId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = currentStep - config.tenure
        return recentMoves.contains { $0.eventId == eventId && $0.step > cutoff }
    }

    /// How often has this event been moved across the whole run?
    func longTermFrequency(eventId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return frequency[eventId] ?? 0
    }

    /// Score multiplier in `[0, 1]` for a candidate event. Combines
    /// short-term tabu penalty and long-term frequency bias.
    /// Callers multiply this into roulette weights before selection.
    func score(eventId: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = currentStep - config.tenure
        let isRecent = recentMoves.contains { $0.eventId == eventId && $0.step > cutoff }

        // Diversification bias: normalise frequency by the max
        // observed frequency so the penalty stays bounded even when
        // a workload has wildly varying event counts.
        let freq = frequency[eventId] ?? 0
        let maxFreq = frequency.values.max() ?? 1
        let freqNorm = maxFreq > 0 ? Double(freq) / Double(maxFreq) : 0
        let diversificationBias = 1.0 - config.frequencyWeight * freqNorm

        let recencyFactor = isRecent ? config.tabuPenalty : 1.0
        return max(0, recencyFactor * diversificationBias)
    }

    /// Aspiration check: is this move allowed despite being tabu
    /// because its projected outcome beats the global best?
    func aspires(hardTier: Double, softTier: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hardTier > bestHardTier { return true }
        if hardTier == bestHardTier && softTier > bestSoftTier { return true }
        return false
    }

    // MARK: - Introspection (for tests / telemetry)

    var currentStepCount: Int {
        lock.lock(); defer { lock.unlock() }
        return currentStep
    }

    var activeTabuCount: Int {
        lock.lock(); defer { lock.unlock() }
        let cutoff = currentStep - config.tenure
        return recentMoves.count { $0.step > cutoff }
    }

    var trackedEventCount: Int {
        lock.lock(); defer { lock.unlock() }
        return frequency.count
    }

    /// Reset memory to a fresh state. Typically called at the start
    /// of a new optimization run on a different workload.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        currentStep = 0
        recentMoves.removeAll(keepingCapacity: true)
        frequency.removeAll(keepingCapacity: true)
        frequencyOrder.removeAll(keepingCapacity: true)
        bestHardTier = -Double.infinity
        bestSoftTier = -Double.infinity
    }
}
