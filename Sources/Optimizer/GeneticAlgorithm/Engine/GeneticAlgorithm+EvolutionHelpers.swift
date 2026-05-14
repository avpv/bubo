import Foundation

// MARK: - GeneticAlgorithm evolution helpers
//
// Three side-routines the main `evolve(_:)` loop in
// `GeneticAlgorithm.swift` reaches for around the per-generation
// cycle:
//
//   • `chcRestart(...)` — CHC-style population restart that preserves
//     a small elite slice and heavily mutates the rest. Lets the
//     engine recover from stagnation without giving up on the run.
//   • `memeticHillClimbStep(...)` — intermediate memetic hill climb
//     applied to the top-K every `memeticHillClimbInterval`
//     generations. Local refinement that propagates back through
//     selection.
//   • `hillClimb(_:steps:)` — SA-hybrid hill climber the memetic step
//     calls, and the one `IslandModelGA` calls as a final polish.
//     Accepts worse moves probabilistically with cooling temperature
//     so shallow local optima don't trap progress.
//
// Extracted from `GeneticAlgorithm.swift`; visibility on
// `chcRestart(...)` and `memeticHillClimbStep(...)` dropped `private`
// (now internal) so the main `evolve(_:)` resolves them cross-file.
// `hillClimb(_:steps:)` was already internal because `IslandModelGA`
// calls it.

public extension GeneticAlgorithm {

    // MARK: - CHC Restart

    /// Keep the top-K elites, regenerate the rest from those elites via
    /// high-rate mutation. "K" = `chcRestartEliteFraction * populationSize`,
    /// clamped to at least `eliteCount` so elitism guarantees survive the
    /// restart. Regenerated individuals are parented on a randomly-chosen
    /// elite each, repaired, and re-evaluated before the GA continues.
    ///
    /// This is CHC Eshelman-style: the "cataclysmic mutation" phase the
    /// algorithm is known for. We don't implement the full HUX/restart
    /// machinery — we're only using the restart idea to replace a hard
    /// stop — but the core hypothesis (preserve structure, perturb the
    /// rest heavily) is the same.
    ///
    /// Internal (was `private`) so `evolve(_:)` in `GeneticAlgorithm.swift`
    /// can call this from `GeneticAlgorithm+EvolutionHelpers.swift`.
    func chcRestart(
        population: inout Population<C>,
        config: GAConfiguration
    ) {
        let n = population.individuals.count
        guard n > 0 else { return }

        // Elite count: from config, bumped to ensure structure survives
        // and the fraction isn't so small we effectively random-restart.
        let fractionBasedElites = Int(Double(n) * config.chcRestartEliteFraction)
        let elitesToKeep = max(config.eliteCount, max(1, fractionBasedElites))

        // Take elites by rawFitness — consistent with bestEver tracking and
        // immune to fitness sharing that may have deflated `fitness`.
        let sorted = population.individuals.sorted { $0.rawFitness > $1.rawFitness }
        let elites = Array(sorted.prefix(elitesToKeep))

        var regenerated: [C] = elites
        regenerated.reserveCapacity(n)

        // Repopulate by cloning a random elite and hammering it with the
        // CHC-level mutation rate. Repair brings it back into feasibility
        // (working hours, overlap, dependencies). Evaluate closes the loop
        // so the next generation's selection sees true fitness.
        while regenerated.count < n {
            let template = elites[context.rng.int(in: 0..<elites.count)]
            var offspring = template
            offspring.mutate(rate: config.chcRestartMutationRate, context: context)
            if config.enableRepair {
                offspring.repair(context: context)
            }
            evaluate(&offspring)
            regenerated.append(offspring)
        }

        population.individuals = regenerated
    }

    // MARK: - Memetic Hill Climb

    /// Run a short SA hill climb on the top `candidates` individuals and
    /// write the refined versions back into the population. Unlike the
    /// final-phase hill climb, this operates *during* evolution so any
    /// improvements compound through subsequent selection rounds.
    ///
    /// Candidates are addressed by index to keep the update O(1) per slot;
    /// we pick the indices of the top individuals by `rawFitness` so fitness
    /// sharing (which deflates `fitness` for crowded niches) doesn't bias
    /// selection toward sparse but poorly-scored solutions.
    ///
    /// Internal (was `private`) so `evolve(_:)` in `GeneticAlgorithm.swift`
    /// can call this from `GeneticAlgorithm+EvolutionHelpers.swift`.
    func memeticHillClimbStep(
        population: inout Population<C>,
        candidates: Int,
        steps: Int
    ) {
        let n = population.individuals.count
        guard n > 0, candidates > 0, steps > 0 else { return }

        // Pick top-K indices by rawFitness. We avoid `sortedByFitness` here
        // because that would rely on the possibly-deflated `fitness` field.
        let topIndices = population.individuals.indices
            .sorted { population.individuals[$0].rawFitness > population.individuals[$1].rawFitness }
            .prefix(min(candidates, n))

        for idx in topIndices {
            let refined = hillClimb(population.individuals[idx], steps: steps)
            // Only accept a strictly better climb. Equal-fitness rewrites
            // are harmless for scoring but could displace a more-diverse
            // twin that the crowding/sharing pressure might prefer.
            if refined.rawFitness > population.individuals[idx].rawFitness {
                population.individuals[idx] = refined
            }
        }
    }

    // MARK: - Local Search (SA-Hybrid Hill Climbing)

    /// Simulated Annealing hybrid hill climbing: applies small perturbations
    /// and accepts improvements deterministically, but also accepts worse solutions
    /// with a probability that decreases over time (temperature cooling).
    /// This allows escaping shallow local optima that pure greedy hill climbing misses.
    ///
    /// - Important: Internal API for `IslandModelGA`. Do not call directly from
    ///   application code.
    func hillClimb(_ chromosome: C, steps: Int) -> C {
        var current = chromosome
        var temperature = 0.05
        let coolingRate = 0.85
        // Per-gene mutation probability for *fine-tuning*. The previous value
        // (0.3) mutated ~30% of genes per step — that's not a local-search
        // neighbourhood, that's a full mutation, so the SA temperature could
        // not actually hold on to good solutions. 0.05 yields ~1 gene changed
        // for typical 10-20 event schedules (and still more than one for very
        // large schedules, which is the right direction).
        let neighborhoodRate = 0.05

        for _ in 0..<steps {
            var neighbor = current
            neighbor.mutate(rate: neighborhoodRate, context: context)
            neighbor.repair(context: context)
            evaluate(&neighbor)

            let delta = neighbor.rawFitness - current.rawFitness
            if delta > 0 {
                // Always accept improvements
                current = neighbor
            } else if temperature > 1e-6 && context.rng.bool(probability: exp(delta / temperature)) {
                // Accept worse solution with SA probability
                current = neighbor
            }

            temperature *= coolingRate
        }

        return current
    }
}
