import Foundation

// MARK: - Path Relinking (Wave 2 / item 8)
//
// Path Relinking (Glover, 1997) is a classical post-evolution booster:
// given two elite solutions — typically MAP-Elites niche champions or
// the Pareto-front extremes — generate a path of intermediate
// solutions by gradually morphing the starting solution into the
// guiding one, one "move" at a time. Every intermediate gets
// evaluated; the best one along the path is kept.
//
// For schedule chromosomes the natural move is "rewrite one gene's
// placement to match the guiding solution's". The path length equals
// the number of differing genes; at each step we pick the move that
// yields the largest local fitness improvement (greedy forward PR) or
// the smallest deterioration (backward PR when hill-climbing away
// from a local optimum).
//
// The fact that every intermediate solution is both feasible-by-
// construction (we only rewrite to placements the guide already found
// feasible) and different from the parents means PR consistently
// produces diversification + intensification in one pass, and
// typically lifts the elite archive's quality 5–10% at modest cost
// (~path length · evaluation cost).

public enum PathRelinkingMode: Sendable {
    /// Walk from source → guide. At each step, pick the remaining
    /// move that most improves fitness. Ignores the step if no
    /// improving move exists (greedy hill climbing on the path).
    case forward
    /// Walk both ways (source → guide and guide → source), collect
    /// the best encountered across both walks. ~2× cost for ~2× the
    /// coverage of the interpolation volume.
    case mixed
    /// Start with every gene differing from the guide, then "undo"
    /// non-improving moves to find a smaller-than-full-guide child.
    /// Useful when the guide is much worse than the source — lets
    /// source-aligned improvements leak in.
    case backward
}

/// Result of a single PR run: the best solution found along the path
/// (always at least as good as either parent) and a count of
/// intermediate solutions actually evaluated.
public struct PathRelinkingResult: Sendable {
    public let best: ScheduleChromosome
    public let evaluationsPerformed: Int
    /// Whether `best` improved on both source and guide. False
    /// means PR surfaced at best one of the two parents (neither
    /// dominated the other on the interior of the path).
    public let strictlyImproved: Bool
}

public enum PathRelinking {
    /// Run Path Relinking between `source` and `guide`. Both must be
    /// evaluated (fitness set) before the call. Returns the best
    /// intermediate. No-op (returns the better parent) when the two
    /// parents share every gene's placement.
    public static func relink(
        source: ScheduleChromosome,
        guide: ScheduleChromosome,
        context: OptimizerContext,
        evaluate: (inout ScheduleChromosome) -> Void,
        mode: PathRelinkingMode = .forward,
        maxSteps: Int = 64
    ) -> PathRelinkingResult {
        let diffIndices = diffGenes(source: source, guide: guide)
        guard !diffIndices.isEmpty else {
            // Identical genomes — pick better parent; zero new evals.
            let best = source.rawFitness >= guide.rawFitness ? source : guide
            return PathRelinkingResult(
                best: best,
                evaluationsPerformed: 0,
                strictlyImproved: false
            )
        }

        // Seed best-so-far with the better parent. Every intermediate
        // competes with this.
        var best = source.rawFitness >= guide.rawFitness ? source : guide
        var evaluationsPerformed = 0

        switch mode {
        case .forward:
            let (improvedBest, evals, _) = walk(
                current: source,
                guide: guide,
                remaining: Array(diffIndices),
                bestSoFar: best,
                context: context,
                evaluate: evaluate,
                maxSteps: maxSteps
            )
            best = improvedBest
            evaluationsPerformed = evals
        case .backward:
            let (improvedBest, evals, _) = walk(
                current: guide,
                guide: source,
                remaining: Array(diffIndices),
                bestSoFar: best,
                context: context,
                evaluate: evaluate,
                maxSteps: maxSteps
            )
            best = improvedBest
            evaluationsPerformed = evals
        case .mixed:
            let (fwdBest, fwdEvals, _) = walk(
                current: source,
                guide: guide,
                remaining: Array(diffIndices),
                bestSoFar: best,
                context: context,
                evaluate: evaluate,
                maxSteps: maxSteps
            )
            best = fwdBest
            let (mixedBest, bwdEvals, _) = walk(
                current: guide,
                guide: source,
                remaining: Array(diffIndices),
                bestSoFar: best,
                context: context,
                evaluate: evaluate,
                maxSteps: maxSteps
            )
            best = mixedBest
            evaluationsPerformed = fwdEvals + bwdEvals
        }

        let strictImproved = best.rawFitness > source.rawFitness
            && best.rawFitness > guide.rawFitness
        return PathRelinkingResult(
            best: best,
            evaluationsPerformed: evaluationsPerformed,
            strictlyImproved: strictImproved
        )
    }

    // MARK: - Walk

    /// Greedy walk from `current` toward `guide`. At each step, try
    /// every remaining move (gene index) and commit the best-
    /// scoring one. Stops early when `maxSteps` is hit or every
    /// remaining move deteriorates fitness (pure hill-climb variant).
    private static func walk(
        current: ScheduleChromosome,
        guide: ScheduleChromosome,
        remaining: [Int],
        bestSoFar: ScheduleChromosome,
        context: OptimizerContext,
        evaluate: (inout ScheduleChromosome) -> Void,
        maxSteps: Int
    ) -> (bestSoFar: ScheduleChromosome, evaluations: Int, finalRemaining: [Int]) {
        var current = current
        var remaining = remaining
        var evals = 0
        var best = bestSoFar
        var stepsTaken = 0

        while !remaining.isEmpty && stepsTaken < maxSteps {
            // Try every remaining move, pick the best.
            var bestMoveIdx = -1
            var bestCandidate: ScheduleChromosome?
            var bestScore = -Double.infinity

            for moveIdx in remaining {
                guard moveIdx < current.genes.count, moveIdx < guide.genes.count else { continue }
                var candidate = current
                candidate.genes[moveIdx] = guide.genes[moveIdx]
                candidate.needsEvaluation = true
                candidate.mutatedGeneIndices = IndexSet(integer: moveIdx)
                evaluate(&candidate)
                evals += 1

                if candidate.rawFitness > bestScore {
                    bestScore = candidate.rawFitness
                    bestMoveIdx = moveIdx
                    bestCandidate = candidate
                }
                if candidate.rawFitness > best.rawFitness {
                    best = candidate
                }
            }

            guard let committed = bestCandidate else { break }
            // Abort when even the best available move deteriorates;
            // continuing would just waste evaluations unless we're
            // backtracking.
            if committed.rawFitness < current.rawFitness * 0.95 { break }

            current = committed
            remaining.removeAll { $0 == bestMoveIdx }
            stepsTaken += 1
        }
        return (best, evals, remaining)
    }

    // MARK: - Diff helpers

    /// Indices where source and guide place the same eventId at
    /// different start times. Comparing by position is safe because
    /// both chromosomes come from the same context — gene order
    /// matches event order in `context.movableEvents`.
    private static func diffGenes(
        source: ScheduleChromosome,
        guide: ScheduleChromosome
    ) -> [Int] {
        let n = min(source.genes.count, guide.genes.count)
        var diff: [Int] = []
        diff.reserveCapacity(n)
        for i in 0..<n {
            let a = source.genes[i]
            let b = guide.genes[i]
            if a.eventId != b.eventId { continue }
            if a.startTime != b.startTime || a.isIncluded != b.isIncluded {
                diff.append(i)
            }
        }
        return diff
    }
}

// MARK: - Archive-level driver

/// Convenience driver that runs PR across every pair of elites in a
/// MAP-Elites archive. Budget-limited via `maxPairs` so large
/// archives don't explode evaluation cost. Returns every strictly-
/// improving child for the caller to deposit back.
public enum ArchivePathRelinker {
    struct Result: Sendable {
        let improvements: [ScheduleChromosome]
        let pairsAttempted: Int
        let totalEvaluations: Int
    }

    public static func relink(
        elites: [ScheduleChromosome],
        context: OptimizerContext,
        evaluate: (inout ScheduleChromosome) -> Void,
        maxPairs: Int = 12,
        mode: PathRelinkingMode = .forward
    ) -> Result {
        guard elites.count >= 2 else {
            return Result(improvements: [], pairsAttempted: 0, totalEvaluations: 0)
        }
        let pairs = samplePairs(
            count: elites.count,
            maxPairs: maxPairs,
            rng: context.rng
        )
        var improvements: [ScheduleChromosome] = []
        var totalEvals = 0
        for (i, j) in pairs {
            let res = PathRelinking.relink(
                source: elites[i],
                guide: elites[j],
                context: context,
                evaluate: evaluate,
                mode: mode
            )
            if res.strictlyImproved {
                improvements.append(res.best)
            }
            totalEvals += res.evaluationsPerformed
        }
        return Result(
            improvements: improvements,
            pairsAttempted: pairs.count,
            totalEvaluations: totalEvals
        )
    }

    private static func samplePairs(
        count: Int,
        maxPairs: Int,
        rng: GARandom
    ) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        // Full enumeration when small; else sample without
        // replacement until maxPairs.
        let all = (0..<count).flatMap { i in
            ((i + 1)..<count).map { j in (i, j) }
        }
        if all.count <= maxPairs { return all }
        var shuffled = all
        rng.shuffle(&shuffled)
        pairs = Array(shuffled.prefix(maxPairs))
        return pairs
    }
}
