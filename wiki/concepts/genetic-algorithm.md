# Genetic algorithm

> **Kind:** concept
> **Sources:** Bubo/Optimizer/GACore/
> **Last ingest:** 2026-05-11
> **Related:** [`fitness-objectives.md`](fitness-objectives.md), [`intents.md`](intents.md), [`../modules/optimizer.md`](../modules/optimizer.md)

## Genome

A `Chromosome` (`Optimizer/GACore/Chromosome.swift`) encodes an assignment of tasks → time slots. Pomodoro sequences have a specialised encoding in `PomodoroSequenceChromosome.swift` so crossover/mutation preserve the work-break alternation invariant.

Free-slot enumeration is handled by `SlotDomain.swift` + `SlotRegistry.swift` — these provide the legal value domain per task.

## Loop

`GeneticAlgorithm.swift` runs the standard cycle: **selection → crossover → mutation → repair → evaluate → archive**. The island-model variant (`IslandModelGA.swift`) runs multiple sub-populations to maintain diversity, exchanging migrants periodically.

## Operators

| Stage | Implementations |
|---|---|
| Selection | `TournamentSelection`, `RouletteWheelSelection` (`Selection.swift`) |
| Crossover | `Crossover.swift`, `ContextualCrossover.swift` (uses solution features) |
| Mutation | `Mutation.swift`, `MutationBandit.swift` (multi-armed bandit picks the mutation operator per workload) |
| Local search | `PathRelinking.swift`, `LNSStrategyBandit.swift` |
| Tabu | `TabuMemory.swift` |
| Repair | `CPSATRepair.swift` (constraint repair) |
| Symmetry | `SymmetryBreaker.swift` |
| RNG | `GARandom.swift` (reproducible) |

## Adaptive elements

- **MutationBandit** learns which mutation operator works best for the current workload signature (`TaskSignature` in `Optimizer/Models/TaskSignature.swift`). Learner state is keyed by signature and kept in an LRU bundle inside `BuboOptimizer`.
- **LNSStrategyBandit** picks an LNS destroy/repair strategy adaptively.
- **GNNWarmStart** seeds the initial population with assignments predicted by a graph-NN model from prior accepted scenarios.
- **TemporalWarmStart** (in `Reoptimizer/`) seeds from the previous solution when the calendar changes incrementally.

## Quality-diversity

`QualityDiversityArchive.swift` (and `Scenarios/MAPElitesArchive.swift`) keep an archive of behaviourally-diverse elites so the user is offered visibly distinct scenarios, not 5 near-duplicates.

## Stopping

`FitnessPlateauDetector.swift` triggers early stopping when improvement stalls. Cancellation is supported when input changes mid-run — see `BuboOptimizer.swift`.

## Diagnostics

`GADebugLog.swift` records evolution telemetry — turn on in `OptimizerTabView` for debugging.

## Outputs

GA → top-K elites → `ScenarioGenerator` → `OptimizerService.scenarios`. The top scenario also feeds `shadowProposal` for one-click accept in `SmartActionsBar`.
