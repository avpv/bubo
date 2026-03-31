import Foundation

// MARK: - Crossover Strategy

enum CrossoverStrategy {
    case singlePoint
    case twoPoint
    case uniform(swapProbability: Double)
}

// MARK: - Crossover

/// Crossover operators for schedule chromosomes.
enum Crossover {

    /// Perform crossover on two parents using the given strategy.
    static func perform(
        _ parent1: ScheduleChromosome,
        _ parent2: ScheduleChromosome,
        strategy: CrossoverStrategy = .singlePoint,
        context: OptimizerContext
    ) -> (ScheduleChromosome, ScheduleChromosome) {
        switch strategy {
        case .singlePoint:
            return parent1.crossover(with: parent2, context: context)
        case .twoPoint:
            return twoPointCrossover(parent1, parent2)
        case .uniform(let prob):
            return uniformCrossover(parent1, parent2, swapProbability: prob)
        }
    }

    // MARK: - Two-Point Crossover

    private static func twoPointCrossover(
        _ p1: ScheduleChromosome,
        _ p2: ScheduleChromosome
    ) -> (ScheduleChromosome, ScheduleChromosome) {
        guard p1.genes.count > 2 else { return (p1, p2) }

        var point1 = Int.random(in: 0..<p1.genes.count)
        var point2 = Int.random(in: 0..<p1.genes.count)
        if point1 > point2 { swap(&point1, &point2) }

        var child1Genes = p1.genes
        var child2Genes = p2.genes

        for i in point1...point2 {
            // Swap time slots between parents
            child1Genes[i] = makeGene(from: p1.genes[i], withTimeOf: p2.genes[i])
            child2Genes[i] = makeGene(from: p2.genes[i], withTimeOf: p1.genes[i])
        }

        return (
            ScheduleChromosome(genes: child1Genes),
            ScheduleChromosome(genes: child2Genes)
        )
    }

    // MARK: - Uniform Crossover

    private static func uniformCrossover(
        _ p1: ScheduleChromosome,
        _ p2: ScheduleChromosome,
        swapProbability: Double
    ) -> (ScheduleChromosome, ScheduleChromosome) {
        var child1Genes = p1.genes
        var child2Genes = p2.genes

        for i in p1.genes.indices {
            if Double.random(in: 0...1) < swapProbability {
                child1Genes[i] = makeGene(from: p1.genes[i], withTimeOf: p2.genes[i])
                child2Genes[i] = makeGene(from: p2.genes[i], withTimeOf: p1.genes[i])
            }
        }

        return (
            ScheduleChromosome(genes: child1Genes),
            ScheduleChromosome(genes: child2Genes)
        )
    }

    // MARK: - Helper

    private static func makeGene(from base: ScheduleGene, withTimeOf donor: ScheduleGene) -> ScheduleGene {
        ScheduleGene(
            eventId: base.eventId,
            startTime: donor.startTime,
            duration: base.duration,
            context: base.context,
            energyCost: base.energyCost,
            priority: base.priority,
            isFocusBlock: base.isFocusBlock
        )
    }
}
