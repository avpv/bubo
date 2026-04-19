import Foundation

// MARK: - Contextual Crossover (Learned Linear Scorer)
//
// Classical GA crossover treats gene positions as exchangeable slots:
// a bit at index `i` from parent A can always swap with the bit at
// index `i` from parent B with the same probability. For scheduling
// that's information-poor — "the 7th gene" has no semantic meaning,
// but "the highest-priority focus block" does.
//
// What this module is, honestly:
//   A small **learned linear scorer** computes a per-gene preference
//   `s = w · features(gene)` where `features` is a 4-dim vector
//   (local fitness, priority, deadline urgency, structural fit) and
//   `w` is updated by a bounded reinforcement step on every reward
//   signal. The crossover converts `(s₁, s₂)` for parent A vs B into
//   a softmax inheritance probability with a tunable temperature.
//
// What this module is **not**:
//   • Not a transformer. There is no self-attention over genes, no
//     query/key/value projection, no positional encoding.
//   • Not a neural network. There is one weight per feature, four
//     total. A perceptron would have more parameters.
//   • Not LLM-guided. We don't call any language model.
//
// The naming "attention head" is a metaphor: scoring multiple
// candidates and picking softly. It's not the architectural concept
// from Transformer papers. Honest naming would be
// `GeneInheritanceScorer` — keeping `GeneAttentionHead` for source
// compatibility but documenting the gap loudly.
//
// Hot-path concurrency:
//   Crossover scores each gene twice (once per parent) per pair, so
//   on a 50-gene genome with 100 offspring we hit `score(...)` ~10000
//   times per generation. Taking an `NSLock` per call would dominate.
//   Instead the head exposes a `snapshot()` that copies the current
//   weights once, and `score(...)` accepts the snapshot — no lock on
//   the hot path. Updates still serialize (rare; 1 per generation).

// MARK: - Gene-level Linear Scorer

/// Compact 5-feature linear scorer used by `ContextualCrossover`.
/// Produces a scalar where higher means "this gene should be
/// inherited." Features are bounded to `[0, 1]` so scores stay bounded
/// regardless of weight drift.
///
/// Features:
///   • `localFitness` — proxy for the gene's contribution to its
///     parent's per-day objective breakdown.
///   • `priority` — the underlying task's priority (0…1).
///   • `deadlineUrgency` — 1 when the gene is at deadline, 0 when
///     no deadline or > 7d slack.
///   • `structuralFit` — penalizes obvious soft-constraint violations
///     (e.g. lunch-window starts).
///   • `backlogFit` — for backlog-tagged genes, 1 when the gene's
///     time rank among the parent's backlog genes matches its position
///     in the user's backlog list, degrading linearly with rank
///     distance. Non-backlog genes get 1 (neutral). Lets the scorer
///     prefer whichever parent arranges backlog tasks closer to the
///     user's drag order — same eventId across parents shares every
///     static feature, so this placement-dependent one is what breaks
///     the symmetry in favour of the better-ordered parent.
///
/// Updates are a bounded gradient step toward the rewarding
/// direction. Weights are clamped to `[0, 3]` so a streak of bad
/// rewards can't blow up the model.
final class GeneAttentionHead: @unchecked Sendable {
    /// Immutable snapshot of the head's weights. Crossover takes one
    /// snapshot per call and uses it for every gene scoring — no lock
    /// on the hot path.
    struct Snapshot: Sendable {
        let weights: [Double]
    }

    /// Default weights; backlogFit starts with a small pull so the
    /// head has a non-zero gradient from the first generation. The
    /// bounded update rule can move it up or down once rewards arrive.
    private var weights: [Double] = [1.0, 0.6, 0.4, 0.3, 0.3]
    private let lock = NSLock()
    private let learningRate: Double

    /// Snapshot for tests/telemetry. One lock acquisition.
    var currentWeights: [Double] {
        lock.lock(); defer { lock.unlock() }
        return weights
    }

    init(learningRate: Double = 0.05) {
        self.learningRate = learningRate
    }

    /// Take a single locked snapshot of the weights. Callers reuse
    /// the snapshot across many `score(...)` calls so the lock fires
    /// once per crossover, not once per gene.
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(weights: weights)
    }

    /// Score a gene against the precomputed weight snapshot. No lock,
    /// pure arithmetic.
    ///
    /// `backlogFitHint` is precomputed per parent (see
    /// `ContextualCrossover.backlogFit(for:…)`) so this hot-path scorer
    /// stays O(1). Pass `1.0` for genes without a backlog tag — that
    /// makes the feature cancel out across the two parents and reduces
    /// to the 4-feature behaviour.
    func score(
        gene: ScheduleGene,
        event: OptimizableEvent?,
        perDayScoreHint: Double,
        backlogFitHint: Double,
        preferences: OptimizerPreferences,
        calendar: Calendar,
        snapshot: Snapshot
    ) -> Double {
        let localFitness = max(0, min(1, perDayScoreHint))
        let priority = gene.priority
        let deadlineUrgency: Double
        if let deadline = event?.deadline {
            let slack = deadline.timeIntervalSince(gene.endTime)
            if slack <= 0 { deadlineUrgency = 1.0 }
            else if slack >= 7 * 86400 { deadlineUrgency = 0 }
            else { deadlineUrgency = 1.0 - min(1.0, slack / (7 * 86400)) }
        } else {
            deadlineUrgency = 0
        }

        let hour = calendar.component(.hour, from: gene.startTime)
        let inLunch = hour >= preferences.lunchWindowStart && hour < preferences.lunchWindowEnd
        let structuralFit: Double = inLunch ? 0.2 : 1.0

        let backlogFit = max(0, min(1, backlogFitHint))

        let w = snapshot.weights
        return w[0] * localFitness
             + w[1] * priority
             + w[2] * deadlineUrgency
             + w[3] * structuralFit
             + (w.count > 4 ? w[4] * backlogFit : 0)
    }

    /// Apply a bounded reinforcement step toward the rewarding
    /// direction. Locked because reward feedback can fire from the
    /// reward closure on any GA worker.
    func updateWeights(features: [Double], rewardSign: Double) {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<weights.count where i < features.count {
            let delta = learningRate * rewardSign * features[i]
            weights[i] = max(0.0, min(3.0, weights[i] + delta))
        }
    }
}

// MARK: - Contextual Crossover

/// Attention-based crossover. Offers a drop-in replacement for the
/// positional strategies in `Crossover` — called through the new
/// `CrossoverStrategy.contextual` case.
enum ContextualCrossover {
    /// Produce two offspring from parents using a learned linear
    /// scorer. Each gene is drawn from whichever parent scores higher,
    /// modulated by a softmax temperature that trades exploration
    /// (higher τ = more stochastic) for exploitation (lower τ = sharper
    /// argmax).
    static func perform(
        _ parent1: ScheduleChromosome,
        _ parent2: ScheduleChromosome,
        context: OptimizerContext,
        head: GeneAttentionHead,
        temperature: Double = 0.5
    ) -> (ScheduleChromosome, ScheduleChromosome) {
        guard parent1.genes.count == parent2.genes.count, !parent1.genes.isEmpty else {
            return (parent1, parent2)
        }

        let cal = context.calendar
        let rng = context.rng
        let prefs = context.preferences

        let eventsById: [String: OptimizableEvent] = Dictionary(
            uniqueKeysWithValues: context.movableEvents.map { ($0.id, $0) }
        )

        // Pull per-day hints from the cached per-day objective
        // breakdown when available; falls back to the full-fitness
        // scalar.
        let p1DayHint = perDayHint(for: parent1, calendar: cal)
        let p2DayHint = perDayHint(for: parent2, calendar: cal)

        // Per-parent backlog-fit map. O(N log N) up front so the
        // per-gene scorer stays a dictionary lookup.
        let backlogIdx = context.backlogIndexMap()
        let p1BacklogFit = backlogFit(for: parent1, backlogIndex: backlogIdx)
        let p2BacklogFit = backlogFit(for: parent2, backlogIndex: backlogIdx)

        // Single locked snapshot — every gene scoring uses the same
        // immutable weight vector. Eliminates per-gene lock contention.
        let weightsSnapshot = head.snapshot()

        var child1Genes = parent1.genes
        var child2Genes = parent2.genes

        let tau = max(0.05, temperature)

        for i in parent1.genes.indices {
            let g1 = parent1.genes[i]
            let g2 = parent2.genes[i]
            let ev = eventsById[g1.eventId]
            let day1 = cal.startOfDay(for: g1.startTime)
            let day2 = cal.startOfDay(for: g2.startTime)
            let h1 = p1DayHint[day1] ?? parent1.rawFitness
            let h2 = p2DayHint[day2] ?? parent2.rawFitness
            let bf1 = p1BacklogFit[g1.eventId] ?? 1.0
            let bf2 = p2BacklogFit[g2.eventId] ?? 1.0

            let s1 = head.score(
                gene: g1, event: ev, perDayScoreHint: h1,
                backlogFitHint: bf1,
                preferences: prefs, calendar: cal, snapshot: weightsSnapshot
            )
            let s2 = head.score(
                gene: g2, event: ev, perDayScoreHint: h2,
                backlogFitHint: bf2,
                preferences: prefs, calendar: cal, snapshot: weightsSnapshot
            )

            // Softmax probability that child1 takes parent2's gene.
            let diff = (s2 - s1) / tau
            let probC1TakesP2 = 1.0 / (1.0 + exp(-diff))

            if rng.bool(probability: probC1TakesP2) {
                child1Genes[i] = g1.withStartTime(g2.startTime)
            }
            // Complementary decision for child2: a gene taken by
            // child1 from parent2 is left intact on child2 (which
            // inherited from p2 by construction), and vice versa.
            if rng.bool(probability: 1.0 - probC1TakesP2) {
                child2Genes[i] = g2.withStartTime(g1.startTime)
            }
        }

        return (
            ScheduleChromosome.makeChild(genes: child1Genes, parents: (parent1, parent2), rng: rng),
            ScheduleChromosome.makeChild(genes: child2Genes, parents: (parent2, parent1), rng: rng)
        )
    }

    // MARK: - Helpers

    /// Per-gene "how close is this gene's time rank to its backlog rank"
    /// map, for a single parent. The scorer reads this in O(1); the map
    /// itself is built in O(N log N) via two sorts over the parent's
    /// backlog-tagged included genes.
    ///
    /// A fit of 1 means the gene's chronological position among backlog
    /// tasks matches its position in the user's backlog exactly. A fit
    /// of 0 means the gene is N − 1 ranks away from where it ought to be.
    /// Non-backlog or dropped genes are absent from the map; callers
    /// should treat "missing" as 1.0 (neutral) so that, for genes
    /// without a user-stated preference, the feature contributes the
    /// same amount to both parents and cancels out in the softmax.
    private static func backlogFit(
        for chromosome: ScheduleChromosome,
        backlogIndex: [String: Int]
    ) -> [String: Double] {
        guard !backlogIndex.isEmpty else { return [:] }
        let tagged = chromosome.genes.filter { gene in
            gene.isIncluded && backlogIndex[gene.eventId] != nil
        }
        guard tagged.count >= 2 else { return [:] }

        // Rank by startTime (earliest = 0). Stable sort keeps the
        // original gene order as a tiebreaker, so two genes at the
        // exact same minute are both judged against the same rank.
        let byTime = tagged.sorted { $0.startTime < $1.startTime }
        var timeRank: [String: Int] = [:]
        timeRank.reserveCapacity(byTime.count)
        for (rank, gene) in byTime.enumerated() {
            timeRank[gene.eventId] = rank
        }

        // Dense rank over backlog indices: the gene's position among
        // the currently-included tagged genes when sorted by
        // `backlogIndex`. Comparing time rank against a sparse
        // `backlogIndex` directly would penalise perfectly-ordered
        // schedules just because some backlog tasks were dropped.
        let byIndex = tagged.sorted {
            (backlogIndex[$0.eventId] ?? Int.max) < (backlogIndex[$1.eventId] ?? Int.max)
        }
        var desiredRank: [String: Int] = [:]
        desiredRank.reserveCapacity(byIndex.count)
        for (rank, gene) in byIndex.enumerated() {
            desiredRank[gene.eventId] = rank
        }

        let spread = max(1, tagged.count - 1)
        var fit: [String: Double] = [:]
        fit.reserveCapacity(tagged.count)
        for gene in tagged {
            let t = timeRank[gene.eventId] ?? 0
            let d = desiredRank[gene.eventId] ?? 0
            fit[gene.eventId] = 1.0 - Double(abs(t - d)) / Double(spread)
        }
        return fit
    }

    /// Aggregate per-day hint from a chromosome's cached objective
    /// breakdown. Returns a day → mean-score map. Empty when the cache
    /// isn't populated yet (e.g. fresh chromosome).
    private static func perDayHint(
        for chromosome: ScheduleChromosome,
        calendar: Calendar
    ) -> [Date: Double] {
        guard let cache = chromosome.perDayObjectiveCache, !cache.isEmpty else {
            return [:]
        }
        // Collect per-day scores across every partitioned objective and
        // average them. Close enough to a real per-day fitness for the
        // purpose of biasing the attention head.
        var daySum: [Date: Double] = [:]
        var dayCount: [Date: Int] = [:]
        for (_, perDay) in cache {
            for (day, score) in perDay {
                daySum[day, default: 0] += score
                dayCount[day, default: 0] += 1
            }
        }
        var result: [Date: Double] = [:]
        for (day, sum) in daySum {
            result[day] = sum / Double(max(1, dayCount[day] ?? 1))
        }
        return result
    }
}
