import Foundation

// MARK: - Mutation Strategy

enum MutationStrategy: Sendable {
    case standard                  // random time shift per gene
    case adaptive(generation: Int) // decreasing rate over generations
}

// MARK: - Mutation

/// Mutation operators for schedule chromosomes.
enum Mutation {

    /// Apply mutation to a chromosome.
    static func apply(
        to chromosome: inout ScheduleChromosome,
        rate: Double,
        strategy: MutationStrategy = .standard,
        context: OptimizerContext
    ) {
        switch strategy {
        case .standard:
            chromosome.mutate(rate: rate, context: context)

        case .adaptive(let generation):
            // Rate decreases as generations progress (simulated annealing flavor)
            let adaptiveRate = rate * max(0.1, 1.0 - Double(generation) / 500.0)
            chromosome.mutate(rate: adaptiveRate, context: context)

        }
    }
}
