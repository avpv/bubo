# Genetic algorithm

> **Kind:** concept
> **Sources:** Sources/BuboOptimizer/GeneticAlgorithm/, Sources/BuboOptimizer/Orchestrator/
> **Last ingest:** 2026-05-12 (rev: corrected Sources/BuboOptimizer/ path refs; added key-types table moved from modules/optimizer.md)
> **Related:** [`fitness-objectives.md`](fitness-objectives.md), [`intents.md`](intents.md), [`../modules/optimizer.md`](../modules/optimizer.md)

## Genome

`protocol Chromosome: Hashable` (in `ChromosomeProtocol.swift`, extracted from the original `Chromosome.swift`) — `Hashable` so duplicate detection in `Population` is O(N) via `Set`, not O(N²). Required surface: `fitness`, `rawFitness`, static `random(context:)`, static `greedy(context:)`, static `greedy(context:variantIndex:)`, `crossover` (default + strategy variant), `mutate(rate:context:)`, `repair(context:)`, `distance(to:) -> Double` normalised to `[0, 1]`.

The concrete `ScheduleChromosome` declaration lives in `Chromosome.swift` (159 L: stored properties + Equatable/Hashable conformance only); its behaviour is split across `Chromosome+Initialization.swift` (random/greedy seeders), `Chromosome+Crossover.swift`, `Chromosome+Mutation.swift` (mutate + LNS dispatch), `Chromosome+Repair.swift` (guided helpers + post-mutation repair), `Chromosome+Distance.swift` (SIMD genotypic distance), `Chromosome+CPSATSeed.swift` (cpSeeded + shared slot helpers), and the LNS repair pipeline split 2026-05-12 into `Chromosome+CPSATRepair.swift` (CP-SAT bridge `applyCPSATRepair` + private `candidateStartTimes`), `Chromosome+LNSDestroy.swift` (`destroy` strategy operator), `Chromosome+CPRepair.swift` (handwritten branch-and-bound `cpRepair`), and `Chromosome+RegretRepair.swift` (regret-based `regretRepair` fallback). Down from a 3487-line monolith.

**`rawFitness` separation** (comment at `ChromosomeProtocol.swift:14–18`): fitness sharing / niching may penalise crowded individuals' visible `fitness`. `bestEver` tracking must use `rawFitness` so a globally-best-but-crowded individual isn't lost.

**Default extensions** (`ChromosomeProtocol.swift:54–79`): strategy-aware crossover falls back to basic; `repair` no-op; `greedy` falls back to `random`; variant-greedy falls back to `greedy`; binary distance (0 if equal, else 1).

**`ScheduleChromosome`** (`Chromosome.swift:8`) — `struct`, `Sendable`, conforms to `Chromosome, AdaptiveMutationChromosome`. Stores `genes: [ScheduleGene]`. Has a one-way invariant flag distinguishing real-evaluator fitness from surrogate predictions: anything the GA emits externally (archived scenarios, metadata, `bestEver` at shutdown) must have the flag true; callers requiring the guarantee force a real `FitnessEvaluator.evaluateAndAssign` when it's false.

Pomodoro sequences use a separate encoding in `PomodoroSequenceChromosome.swift` so crossover/mutation preserve the work-break alternation invariant.

Free-slot enumeration is handled by `SlotDomain.swift` + `SlotRegistry.swift` — these provide the legal value domain per task.

## Loop

The **default** evolution path is the island-model GA (`Sources/BuboOptimizer/GeneticAlgorithm/IslandModelGA.swift`, class at `:53`) with multiple parallel populations and periodic migration — explicitly stated in the `BuboOptimizer.optimize(...)` doc comment (`BuboOptimizer.swift:161`). The single-population `GeneticAlgorithm.swift` (`:8`) is the underlying engine each island instantiates. Both share the standard cycle: **selection → crossover → mutation → repair → evaluate → archive**.

Configuration: `BuboOptimizer.gaConfig: GAConfiguration = .default`, `BuboOptimizer.islandConfig: IslandConfiguration = .default` (struct at `IslandConfiguration.swift:8`).

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

Each workload (identified by `TaskSignature` in `Sources/BuboOptimizer/Models/TaskSignature.swift`) gets its own bundle of learners — `BuboOptimizer.WorkloadLearners` at `Sources/BuboOptimizer/Orchestrator/BuboOptimizer.swift`. The bundle holds **four** classes, all stateful and workload-sensitive:

| Component | Type | Role |
|---|---|---|
| Mutation bandit | `MutationBandit` (`Sources/BuboOptimizer/GeneticAlgorithm/MutationBandit.swift`) | LinUCB over 5 operators — `shift` (±30-min jitter), `moveDay` (relocate to random day), `snap` (half-hour grid), `guided` (find nearest gap), `lnsDay` (LNS: atomic destroy/repair, once per `mutate()`). Conditions on graph-derived features (`precedenceViolationRate`, `conflictDensity`, `maxChainDepth`) |
| LNS strategy bandit | `LNSStrategyBandit` | Picks an LNS destroy/repair strategy adaptively |
| Gene-attention head | `class GeneAttentionHead` (`Sources/BuboOptimizer/GeneticAlgorithm/ContextualCrossover.swift:67`) | Learned linear scorer over 5 bounded features; reinforcement-style weight updates. Biases crossover toward higher-attention genes |
| RBF surrogate | `RBFSurrogate` in `Sources/BuboOptimizer/Fitness/Surrogate.swift` | Predicts fitness for cheap-to-evaluate offspring (see [`fitness-objectives.md`](fitness-objectives.md)) |

LRU cap is `BuboOptimizer.maxCachedLearnerBundles: Int = 8` (`BuboOptimizer.swift:80`). Two `optimize()` calls on the same workload signature reuse the bundle; different workloads get fresh learners.

Additional warm-start hooks (not in the bundle, but global):

- **GNNWarmStart** is a **training-free** small GNN (`GNNWarmStart.swift:5`, weights `MessagePassingWeights.heuristic` at `:58`) over the conflict / precedence graphs. Produces per-event priority scores for greedy initial seeding. A separate `GNNWarmStartTrainer` (`:357`) can refine the weights from observed outcomes.
- **TemporalWarmStart** (in `Reoptimizer/`) seeds from the previous solution when the calendar changes incrementally.

## Quality-diversity

Two separate MAP-Elites archives with different behavior spaces:

- `Sources/BuboOptimizer/GeneticAlgorithm/QualityDiversityArchive.swift` — `struct BehaviorDescriptor` at `:32`. **4D** behavior space (focus, morning skew, day spread, precedence tightness). Used inside evolution to maintain diverse elites.
- `Sources/BuboOptimizer/Scenarios/MAPElitesArchive.swift` — `struct MAPElitesArchive` at `:79`. **3D 5×5×5 = 125 cells** by `(taskSpreadDays, morningShare, lastTaskHour)`. Used post-GA to back the scenario picker so the user is offered visibly distinct options, not 5 near-duplicates.

## Stopping

`FitnessPlateauDetector.swift` triggers early stopping when improvement stalls. Cancellation is supported when input changes mid-run — see `BuboOptimizer.swift`.

## Diagnostics

`GADebugLog.swift` records evolution telemetry — turn on in `OptimizerTabView` for debugging.

## Outputs

GA → top-K elites → `ScenarioGenerator` → `OptimizerService.scenarios`. The top scenario also feeds `shadowProposal` for one-click accept in `SmartActionsBar`.

## Key types in Sources/BuboOptimizer/GeneticAlgorithm/

Each row verified by reading the file header.

| File | Main Type | Role |
|---|---|---|
| `Chromosome.swift` + 12 siblings | `struct ScheduleChromosome` | The 3487-line original was decomposed: `Chromosome.swift` (~159 L) keeps the struct declaration + stored properties; behaviour split across `ChromosomeProtocol.swift` (protocol + default impls), `+Initialization`, `+Crossover`, `+Mutation` (mutate + LNS dispatch), `+Repair`, `+CPSATSeed`, `+CPSATRepair` (CP-SAT bridge), `+LNSDestroy`, `+CPRepair` (branch-and-bound), `+RegretRepair`, `+Distance` (SIMD), and `ScheduleHorizonHelpers.swift` |
| `PomodoroSequenceChromosome.swift` | `struct PomodoroSequenceChromosome` (`:12`) | Task-order permutation within time blocks. Order Crossover (OX1). Energy/deadline-aware fitness |
| `GeneticAlgorithm.swift` + 4 siblings | `final class GeneticAlgorithm<C: Chromosome>` | 633 L engine + `GAConfiguration.swift` (named presets), `MultiObjectiveContext.swift` (NSGA-III hookup), `+EvolutionHelpers` (CHC restart, hill climb), `+BanditFeatures` (`graphBanditFeatures`, `objectiveImbalance`) |
| `IslandModelGA.swift` + 4 siblings | `final class IslandModelGA<C: Chromosome>` | **Default evolution path.** 612 L engine + `IslandConfiguration.swift` (Sendable config types), `+Configurations` (per-island GA-config generator), `+Migration` (migrate/destroy/select/insert pipeline), `+Diversity` (`measureCrossIslandDiversity`) |
| `Population.swift` | `struct Population<C: Chromosome>` (`:6`) | Population manager with elitism, parallel evaluation, generation replacement |
| `Selection.swift` | `enum Selection` (`:19`) | Tournament, roulette, rank, stochastic universal sampling |
| `Crossover.swift` | `enum Crossover` (`:38`) | Single-point, two-point, uniform, day-block, contextual, graph-aware subtree |
| `ContextualCrossover.swift` | `class GeneAttentionHead` (`:67`) | Learned linear scorer over 5 features; reinforcement-style weight updates |
| `Mutation.swift` | `enum Mutation` (`:13`) | Standard or adaptive (generation-decaying) mutation rates |
| `MutationBandit.swift` | `enum MutationOperator` (`:9`), `class MutationBandit` (`:134`) | LinUCB over 5 operators; `LNSStrategyBandit` + `LNSRepairBandit` for adaptive LNS |
| `DifferentiableRelaxation.swift` | `struct ScheduleGradientRefiner` (`:30`) | Gradient-based post-GA refinement of soft fitness terms |
| `PathRelinking.swift` | `enum PathRelinking` (`:54`) | Post-evolution booster — morphs between elites for improved offspring |
| `SymmetryBreaker.swift` | `enum SymmetryBreaker` (`:36`) | Canonicalizes chromosomes; improves fitness-cache hit rate |
| `TabuMemory.swift` | `final class TabuMemory` (`:25`) | Short-term + long-term tabu memory; tenure-based recency, frequency diversification |
| `CPSATRepair.swift` | `struct CPSATAssignment` (`:74`) | CDCL-lite solver with Luby restarts. Used for repair and as a construction seed |
| `SlotDomain.swift` | `struct SlotDomain` (`:32`) | Precomputed feasible slot indices per movable event |
| `SlotRegistry.swift` | `struct SlotRegistry` (`:30`) | Precomputed list of every valid start time in the horizon |
| `GARandom.swift` | `final class GARandom` (`:28`) | Seedable deterministic RNG, SplitMix64 backend |
| `EvolutionHooks.swift` | `struct EvolutionHooks<C: Chromosome>` (`:30`) | Optional closures at evolution events — feeds QD archive, drives gradient refinement |
| `FitnessPlateauDetector.swift` | `struct FitnessPlateauDetector` (`:30`) | Early stopping via rolling-window relative-stdev test |
| `QualityDiversityArchive.swift` | `struct BehaviorDescriptor` (`:32`) | MAP-Elites archive, 4D behavior space |
| `GADebugLog.swift` | `enum GADebugLog` (`:36`) | Structured GA diagnostics via OSLog |
| `GNNWarmStart.swift` | `struct MessagePassingWeights` (`:45`) | Training-free small GNN over conflict/precedence graphs for greedy seeding |
