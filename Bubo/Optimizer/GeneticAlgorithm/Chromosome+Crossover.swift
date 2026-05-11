import Foundation

// MARK: - ScheduleChromosome crossover
//
// Single-point order-based crossover plus the `makeChild(...)` helper
// that propagates self-adaptive mutation rates from parents to
// children (mean ± 5% jitter). Strategy-aware crossover delegates
// out to the `Crossover` enum's `perform(...)` dispatcher.
//
// Extracted from `Chromosome.swift` so the crossover surface lives
// next to the operator menu the GA picks from — small file, easy to
// find when tuning crossover behaviour.

extension ScheduleChromosome {

    // MARK: - Crossover (Order-based)

    func crossover(with other: ScheduleChromosome, context: OptimizerContext) -> (ScheduleChromosome, ScheduleChromosome) {
        guard genes.count > 1, genes.count == other.genes.count else { return (self, other) }

        let point = context.rng.int(in: 1..<genes.count)

        var child1Genes = Array(genes[..<point])
        var child2Genes = Array(other.genes[..<point])

        // Fill remaining genes from the other parent — swap time slots.
        // `withPlacement` carries both `startTime` and `slotIndex`
        // across so crossover doesn't erase the donor's slot binding.
        for i in point..<genes.count {
            child1Genes.append(genes[i].withPlacement(from: other.genes[i]))
            child2Genes.append(other.genes[i].withPlacement(from: genes[i]))
        }

        return (
            Self.makeChild(genes: child1Genes, parents: (self, other), rng: context.rng),
            Self.makeChild(genes: child2Genes, parents: (other, self), rng: context.rng)
        )
    }

    /// Build a crossover child. Factored out so every crossover strategy
    /// (singlePoint, twoPoint, uniform, dayBlock) propagates self-adaptive
    /// parameters the same way: child.rate = mean(parents) jittered by ±5%.
    /// Jitter keeps the rate-gene under selection pressure; without it the
    /// whole population would converge on the mean almost immediately.
    static func makeChild(
        genes: [ScheduleGene],
        parents: (ScheduleChromosome, ScheduleChromosome),
        rng: GARandom
    ) -> ScheduleChromosome {
        var child = ScheduleChromosome(genes: genes, needsEvaluation: true)
        let p1 = parents.0.selfAdaptiveMutationRate
        let p2 = parents.1.selfAdaptiveMutationRate
        if p1 > 0 || p2 > 0 {
            let mean = (p1 + p2) / (p1 > 0 && p2 > 0 ? 2.0 : 1.0)
            let jitter = rng.double(in: -0.05...0.05) * mean
            child.selfAdaptiveMutationRate = min(0.8, max(0.01, mean + jitter))
        }
        return child
    }

    /// Strategy-aware crossover that delegates to the Crossover enum.
    func crossover(with other: ScheduleChromosome, strategy: CrossoverStrategy, context: OptimizerContext) -> (ScheduleChromosome, ScheduleChromosome) {
        Crossover.perform(self, other, strategy: strategy, context: context)
    }
}
