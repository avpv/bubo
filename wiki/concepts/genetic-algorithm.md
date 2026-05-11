# Genetic algorithm

> **Kind:** concept
> **Sources:** Bubo/Optimizer/GACore/
> **Last ingest:** 2026-05-11
> **Related:** [`fitness-objectives.md`](fitness-objectives.md), [`intents.md`](intents.md), [`../modules/optimizer.md`](../modules/optimizer.md)

## Genome

`protocol Chromosome: Hashable` (`Chromosome.swift:12`) — `Hashable` so duplicate detection in `Population` is O(N) via `Set`, not O(N²). Required surface: `fitness`, `rawFitness`, static `random(context:)`, static `greedy(context:)`, static `greedy(context:variantIndex:)`, `crossover` (default + strategy variant), `mutate(rate:context:)`, `repair(context:)`, `distance(to:) -> Double` normalised to `[0, 1]`.

**`rawFitness` separation** (comment at `Chromosome.swift:18–22`): fitness sharing / niching may penalise crowded individuals' visible `fitness`. `bestEver` tracking must use `rawFitness` so a globally-best-but-crowded individual isn't lost.

**Default extensions** (`Chromosome.swift:54–78`): strategy-aware crossover falls back to basic; `repair` no-op; `greedy` falls back to `random`; variant-greedy falls back to `greedy`; binary distance (0 if equal, else 1).

**`ScheduleChromosome`** (`Chromosome.swift:85`) — `struct`, `Sendable`, conforms to `Chromosome, AdaptiveMutationChromosome`. Stores `genes: [ScheduleGene]`. Has a one-way invariant flag distinguishing real-evaluator fitness from surrogate predictions: anything the GA emits externally (archived scenarios, metadata, `bestEver` at shutdown) must have the flag true; callers requiring the guarantee force a real `FitnessEvaluator.evaluateAndAssign` when it's false.

Pomodoro sequences use a separate encoding in `PomodoroSequenceChromosome.swift` so crossover/mutation preserve the work-break alternation invariant.

Free-slot enumeration is handled by `SlotDomain.swift` + `SlotRegistry.swift` — these provide the legal value domain per task.

## Loop

The **default** evolution path is the island-model GA (`Optimizer/GACore/IslandModelGA.swift`, class at `:234`) with multiple parallel populations and periodic migration — explicitly stated in the `BuboOptimizer.optimize(...)` doc comment (`BuboOptimizer.swift:164–166`). The single-population `GeneticAlgorithm.swift` (`:404`) is the underlying engine each island instantiates. Both share the standard cycle: **selection → crossover → mutation → repair → evaluate → archive**.

Configuration: `BuboOptimizer.gaConfig: GAConfiguration = .default`, `BuboOptimizer.islandConfig: IslandConfiguration = .default` (struct at `IslandModelGA.swift:8`).

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

Each workload (identified by `TaskSignature` in `Optimizer/Models/TaskSignature.swift`) gets its own bundle of learners — `BuboOptimizer.WorkloadLearners` at `Bubo/Optimizer/BuboOptimizer.swift:67–79`. The bundle holds **four** classes, all stateful and workload-sensitive:

| Component | Type | Role |
|---|---|---|
| Mutation bandit | `MutationBandit` (`Optimizer/GACore/MutationBandit.swift`) | LinUCB over 5 operators — `shift` (±30-min jitter), `moveDay` (relocate to random day), `snap` (half-hour grid), `guided` (find nearest gap), `lnsDay` (LNS: atomic destroy/repair, once per `mutate()`). Conditions on graph-derived features (`precedenceViolationRate`, `conflictDensity`, `maxChainDepth`) |
| LNS strategy bandit | `LNSStrategyBandit` | Picks an LNS destroy/repair strategy adaptively |
| Gene-attention head | `class GeneAttentionHead` (`Bubo/Optimizer/GACore/ContextualCrossover.swift:67`) | Learned linear scorer over 5 bounded features; reinforcement-style weight updates. Biases crossover toward higher-attention genes |
| RBF surrogate | `RBFSurrogate` in `Optimizer/Fitness/Surrogate.swift` | Predicts fitness for cheap-to-evaluate offspring (see [`fitness-objectives.md`](fitness-objectives.md)) |

LRU cap is `BuboOptimizer.maxCachedLearnerBundles: Int = 8` (`BuboOptimizer.swift:89`). Two `optimize()` calls on the same workload signature reuse the bundle; different workloads get fresh learners.

Additional warm-start hooks (not in the bundle, but global):

- **GNNWarmStart** is a **training-free** small GNN (`GNNWarmStart.swift:5`, weights `MessagePassingWeights.heuristic` at `:58`) over the conflict / precedence graphs. Produces per-event priority scores for greedy initial seeding. A separate `GNNWarmStartTrainer` (`:357`) can refine the weights from observed outcomes.
- **TemporalWarmStart** (in `Reoptimizer/`) seeds from the previous solution when the calendar changes incrementally.

## Quality-diversity

Two separate MAP-Elites archives with different behavior spaces:

- `Optimizer/GACore/QualityDiversityArchive.swift` — `struct BehaviorDescriptor` at `:32`. **4D** behavior space (focus, morning skew, day spread, precedence tightness). Used inside evolution to maintain diverse elites.
- `Optimizer/Scenarios/MAPElitesArchive.swift` — `struct MAPElitesArchive` at `:79`. **3D 5×5×5 = 125 cells** by `(taskSpreadDays, morningShare, lastTaskHour)`. Used post-GA to back the scenario picker so the user is offered visibly distinct options, not 5 near-duplicates.

## Stopping

`FitnessPlateauDetector.swift` triggers early stopping when improvement stalls. Cancellation is supported when input changes mid-run — see `BuboOptimizer.swift`.

## Diagnostics

`GADebugLog.swift` records evolution telemetry — turn on in `OptimizerTabView` for debugging.

## Outputs

GA → top-K elites → `ScenarioGenerator` → `OptimizerService.scenarios`. The top scenario also feeds `shadowProposal` for one-click accept in `SmartActionsBar`.
