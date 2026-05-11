import Foundation

// MARK: - GeneticAlgorithm bandit-context features
//
// Two helpers `evolveOneGeneration(...)` calls every cycle to build
// the `MutationBandit` context vector:
//
//   • `graphBanditFeatures(in:context:)` — schedule-conflict-graph
//     summary (component count, max component size, average degree,
//     etc.). Lets the LinUCB bandit pick LNS-friendly operators when
//     the workload looks tangled.
//   • `objectiveImbalance(in:)` — std-dev of the per-objective score
//     vector across the population; nudges the bandit toward
//     operators that perturb the underexplored axes.
//
// Extracted from `GeneticAlgorithm.swift` so the bandit-feature
// surface lives next to the bandit consumer (`evolveOneGeneration`)
// rather than buried at the end of the engine class. Visibility on
// both helpers was relaxed from `private`/`fileprivate` to internal —
// see comments at the matching call sites in `GeneticAlgorithm.swift`.

extension GeneticAlgorithm {

    // MARK: - Graph Bandit Features

    /// Graph-derived bandit context features summarised into a tuple so
    /// the caller can splat them into `BanditContext`. Non-schedule
    /// chromosomes return zeros — the bandit then behaves like the
    /// pre-graph implementation on those workloads.
    // Internal (was `fileprivate`) so `evolveOneGeneration(...)` in
    // `GeneticAlgorithm.swift` can name the return type of
    // `graphBanditFeatures(...)` after the helper moved here.
    struct GraphBanditFeatures {
        var precedenceViolationRate: Double = 0
        var conflictDensity: Double = 0
        var maxChainDepth: Double = 0
    }

    /// Compute graph features for the bandit context. Looks up the
    /// best individual (by rawFitness) and, when the chromosome is a
    /// `ScheduleChromosome`, queries the conflict graph for structural
    /// metrics. Static so the schedule-specific branch can be read by
    /// `evolveOneGeneration` without dragging the cast into the hot
    /// method body.
    ///
    /// Internal static (was `fileprivate`) so `evolveOneGeneration(...)`
    /// in `GeneticAlgorithm.swift` can call it after we moved it to
    /// `GeneticAlgorithm+BanditFeatures.swift`.
    static func graphBanditFeatures(
        in population: Population<C>,
        context: OptimizerContext
    ) -> GraphBanditFeatures {
        guard let best = population.individuals.max(by: { $0.rawFitness < $1.rawFitness }) else {
            return GraphBanditFeatures()
        }
        // The GA is generic over chromosome type, so we dip into the
        // schedule-specific representation only when the cast succeeds.
        // Pomodoro and other chromosome flavours get a neutral feature
        // set — no behavioural change.
        guard let scheduleBest = best as? ScheduleChromosome else {
            return GraphBanditFeatures()
        }
        let graph = context.ensureConflictGraph()
        guard graph.eventIds.count > 0 else { return GraphBanditFeatures() }

        // Precedence violation rate: fraction of direct dependency
        // edges with gap < 0 on the best individual. Zero by
        // construction once repair runs successfully, so this mostly
        // signals "the GA is trying to crack a very tight packing
        // problem" during early generations.
        var geneByEvent: [String: ScheduleGene] = [:]
        for gene in scheduleBest.genes where gene.isIncluded {
            geneByEvent[gene.eventId] = gene
        }
        var violations = 0
        var pairs = 0
        for (prereq, dependents) in graph.directPrecedes {
            guard let prereqGene = geneByEvent[prereq] else { continue }
            for dep in dependents {
                guard let depGene = geneByEvent[dep] else { continue }
                pairs += 1
                if depGene.startTime < prereqGene.endTime {
                    violations += 1
                }
            }
        }
        let precedenceViolationRate = pairs > 0
            ? Double(violations) / Double(pairs)
            : 0

        return GraphBanditFeatures(
            precedenceViolationRate: precedenceViolationRate,
            conflictDensity: graph.conflictDensity,
            maxChainDepth: graph.maxChainDepth
        )
    }

    // MARK: - Objective Imbalance (bandit context feature)

    /// Std dev across objective scores on the population's current best
    /// individual, mapped to [0, 1]. High values mean one objective is
    /// dominating — telling the bandit "switch tactics." Returns 0 when
    /// no multi-objective breakdown is available.
    // Internal (was `private`) so `evolveOneGeneration(...)` in
    // `GeneticAlgorithm.swift` can call it after we moved the
    // implementation into `GeneticAlgorithm+BanditFeatures.swift`.
    func objectiveImbalance(in population: Population<C>) -> Double {
        guard let mo = multiObjective else { return 0 }
        guard let best = population.individuals.max(by: { $0.rawFitness < $1.rawFitness }) else { return 0 }
        let v = mo.objectiveVectorOf(best)
        guard v.count > 1 else { return 0 }
        let mean = v.reduce(0, +) / Double(v.count)
        let variance = v.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count)
        // Max std dev on a [0, 1]-clamped vector is 0.5 (half ones, half zeros),
        // so dividing by 0.5 gives a [0, 1] range.
        return min(1.0, variance.squareRoot() / 0.5)
    }
}
