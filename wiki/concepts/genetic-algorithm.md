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

- **MutationBandit** (`Optimizer/GACore/MutationBandit.swift`) is a **LinUCB** contextual bandit over five named operators (`MutationOperator` enum at `MutationBandit.swift:9`):
  - `shift` — ±30-min local jitter (fastest, tight neighbourhoods)
  - `moveDay` — relocate to a random day in the horizon (global explore)
  - `snap` — half-hour grid alignment (cheap cleanup)
  - `guided` — find nearest free gap that fits (highest avg reward near-feasible)
  - `lnsDay` — Large Neighborhood Search: destroy a coherent subset (day or top-K), greedy reinsert. Runs once per `mutate()` call (atomic destroy/repair), not per gene.

  The bandit conditions on a `BanditContext` of [0,1] features including graph-derived ones (`precedenceViolationRate`, `conflictDensity`, `maxChainDepth`) so operator choice tracks the current GA regime. Bandit state is kept per workload in an LRU bundle inside `BuboOptimizer`, keyed by `TaskSignature` (`Optimizer/Models/TaskSignature.swift`).
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
