import Foundation

// MARK: - Multi-Objective Selection Hook

/// Plumbing that lets the generic `GeneticAlgorithm<C>` invoke NSGA-III
/// survivor selection when the chromosome exposes per-objective scores.
/// Chromosomes without a multi-objective breakdown (e.g. permutation
/// genomes used by `PomodoroSequenceChromosome`) pass `nil` and the
/// engine falls back to scalar-fitness generational replacement.
public struct MultiObjectiveContext<C: Chromosome>: @unchecked Sendable {

    public init(
        adaptiveRanker: AdaptiveNSGA3,
        objectiveVectorOf: @escaping (C) -> [Double],
        hypervolume: HypervolumeEstimator
    ) {
        self.adaptiveRanker = adaptiveRanker
        self.objectiveVectorOf = objectiveVectorOf
        self.hypervolume = hypervolume
    }

    /// Adaptive NSGA-III ranker. Reference points grow around crowded
    /// niches and prune vacant ones (Jain & Deb, 2014). There is no
    /// static-ranker alternative — the adaptive variant subsumes the
    /// fixed Das–Dennis grid as its initial state.
    public let adaptiveRanker: AdaptiveNSGA3

    public let objectiveVectorOf: (C) -> [Double]

    /// Hypervolume estimator used for last-front tiebreaking inside
    /// survivor selection.
    public let hypervolume: HypervolumeEstimator

    /// Ranker snapshot for the current generation. Taken from the
    /// adaptive variant so reference-point evolution is observed by
    /// every selection call.
    public var activeRanker: NSGA3 { adaptiveRanker.currentRanker }

    /// Produce the NSGA-III harness for the default 13-objective
    /// ScheduleChromosome evaluator. Reads `objectiveCache` directly so
    /// no extra evaluation runs during survivor selection.
    public static func schedule(
        evaluator: FitnessEvaluator,
        populationSize: Int,
        hypervolumeSampleCount: Int = 8_000,
        hypervolumeSeed: UInt64 = 0x5EED_F2_2026
    ) -> MultiObjectiveContext<ScheduleChromosome> {
        let names = evaluator.objectives.map(\.name)
        // Combined parent + offspring pool is 2·N, so feed NSGA-III that
        // many reference directions — each individual can be associated
        // with a distinct direction in dense regions of the simplex.
        let base = NSGA3.forPopulation(
            objectiveCount: names.count,
            populationSize: max(2, populationSize * 2)
        )
        let adaptive = AdaptiveNSGA3(base: base)
        let hv = HypervolumeEstimator(
            objectiveCount: names.count,
            sampleCount: hypervolumeSampleCount,
            seed: hypervolumeSeed
        )
        return MultiObjectiveContext<ScheduleChromosome>(
            adaptiveRanker: adaptive,
            objectiveVectorOf: { chromosome in
                if let cache = chromosome.objectiveCache, !cache.isEmpty {
                    return names.map { cache[$0] ?? 0.0 }
                }
                return names.map { _ in 0.0 }
            },
            hypervolume: hv
        )
    }
}
