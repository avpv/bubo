# Genetic algorithm

> **Kind:** concept
> **Sources:** Sources/Optimizer/GeneticAlgorithm/{Core,Operators,Repair,Adaptive,IslandModel,Engine}/, Sources/Optimizer/Orchestrator/
> **Last ingest:** 2026-07-16 (rev: core-audit correctness fixes — `.rank` selection off-by-one corrected (worst individual was never selectable); the MO path re-inserts `bestEver` before returning; `mutatedGeneIndices` accumulates by union and survives constraint-rejected evals (delta caches stay coherent with their snapshot); `MutationBandit.record(op:reward:context:)` pairs rewards with the calling island's generation context; `.random` immigrant replacement shields elites by rawFitness; repair's gap relocation rejects backward working-hours clamps and retries snaps with `SlotRegistry.indexAtOrAfter`; `findFirstFreeSlot` no longer skips the deadline day; `enumerateFeasibleSlots` filters `workingDays`. Prior rev 2026-05-14: line refs resynced for `ChromosomeProtocol.swift`, `BuboOptimizer.swift`, `Chromosome.swift`, `MAPElitesArchive`)
> **Related:** [`fitness-objectives.md`](fitness-objectives.md), [`intents.md`](intents.md), [`../modules/optimizer.md`](../modules/optimizer.md)

## Genome

`protocol Chromosome: Hashable` (in `ChromosomeProtocol.swift`, extracted from the original `Chromosome.swift`) — `Hashable` so duplicate detection in `Population` is O(N) via `Set`, not O(N²). Required surface: `fitness`, `rawFitness`, static `random(context:)`, static `greedy(context:)`, static `greedy(context:variantIndex:)`, `crossover` (default + strategy variant), `mutate(rate:context:)`, `repair(context:)`, `distance(to:) -> Double` normalised to `[0, 1]`.

The concrete `ScheduleChromosome` declaration lives in `Chromosome.swift` (194 L: stored properties + Equatable/Hashable conformance only); its behaviour is split across `Chromosome+Initialization.swift` (random/greedy seeders), `Chromosome+Crossover.swift`, `Chromosome+Mutation.swift` (mutate + LNS dispatch), `Chromosome+Repair.swift` (guided helpers + post-mutation repair), `Chromosome+Distance.swift` (SIMD genotypic distance), `Chromosome+CPSATSeed.swift` (cpSeeded entry point only, 326 L after the 2026-05-13 split), `Chromosome+SlotSearch.swift` (the four slot-search helpers split out 2026-05-13: `findFirstFreeSlot`, `findLastFreeSlot`, `enumerateFeasibleSlots`, `OccupiedInterval` — all already `public static`, no visibility change), and the LNS repair pipeline split 2026-05-12 into `Chromosome+CPSATRepair.swift` (CP-SAT bridge `applyCPSATRepair` + private `candidateStartTimes`), `Chromosome+LNSDestroy.swift` (`destroy` strategy operator), `Chromosome+CPRepair.swift` (handwritten branch-and-bound `cpRepair`), and `Chromosome+RegretRepair.swift` (regret-based `regretRepair` fallback). Down from a 3487-line monolith.

**`rawFitness` separation** (comment at `ChromosomeProtocol.swift:16–19`): fitness sharing / niching may penalise crowded individuals' visible `fitness`. `bestEver` tracking must use `rawFitness` so a globally-best-but-crowded individual isn't lost.

**Default extensions** (`ChromosomeProtocol.swift:53–80`): strategy-aware crossover falls back to basic; `repair` no-op; `greedy` falls back to `random`; variant-greedy falls back to `greedy`; binary distance (0 if equal, else 1).

**`ScheduleChromosome`** (`Chromosome.swift:8`) — `struct`, `Sendable`, conforms to `Chromosome, AdaptiveMutationChromosome`. Stores `genes: [ScheduleGene]`. Has a one-way invariant flag distinguishing real-evaluator fitness from surrogate predictions: anything the GA emits externally (archived scenarios, metadata, `bestEver` at shutdown) must have the flag true; callers requiring the guarantee force a real `FitnessEvaluator.evaluateAndAssign` when it's false.

Pomodoro sequences use a separate encoding in `PomodoroSequenceChromosome.swift` so crossover/mutation preserve the work-break alternation invariant.

Free-slot enumeration is handled by `SlotDomain.swift` + `SlotRegistry.swift` — these provide the legal value domain per task.

## Loop

The **default** evolution path is the island-model GA (`Optimizer/GeneticAlgorithm/IslandModel/IslandModelGA.swift`, class at `:53`) with multiple parallel populations and periodic migration — explicitly stated in the `BuboOptimizer.optimize(...)` doc comment (`BuboOptimizer.swift:162`). The single-population `GeneticAlgorithm.swift` (`:8`) is the underlying engine each island instantiates. Both share the standard cycle: **selection → crossover → mutation → repair → evaluate → archive**.

Configuration: `BuboOptimizer.gaConfig: GAConfiguration = .default`, `BuboOptimizer.islandConfig: IslandConfiguration = .default` (struct at `IslandConfiguration.swift:8`).

## Operators

| Stage | Implementations |
|---|---|
| Selection | `TournamentSelection`, `RouletteWheelSelection` (`Operators/Selection.swift`) |
| Crossover | `Operators/Crossover.swift`, `Operators/ContextualCrossover.swift` (uses solution features) |
| Mutation | `Operators/Mutation.swift`, `Adaptive/MutationBandit.swift` (multi-armed bandit picks the mutation operator per workload) |
| Local search | `IslandModel/PathRelinking.swift`, `Adaptive/LNSBandit.swift` (destroy + repair bandits, split out of `MutationBandit.swift` on 2026-05-13) |
| Tabu | `Adaptive/TabuMemory.swift` |
| Repair | `Repair/CPSATRepair.swift` (constraint repair) |
| Symmetry | `Operators/SymmetryBreaker.swift` |
| RNG | `Core/GARandom.swift` (reproducible) |

## Adaptive elements

Each workload (identified by `TaskSignature` in `Optimizer/Models/TaskSignature.swift`) gets its own bundle of learners — `BuboOptimizer.WorkloadLearners` at `Sources/Optimizer/Orchestrator/BuboOptimizer.swift`. The bundle holds **four** classes, all stateful and workload-sensitive:

| Component | Type | Role |
|---|---|---|
| Mutation bandit | `MutationBandit` (`Optimizer/GeneticAlgorithm/Adaptive/MutationBandit.swift`) | LinUCB over 5 operators — `shift` (±30-min jitter), `moveDay` (relocate to random day), `snap` (half-hour grid), `guided` (find nearest gap), `lnsDay` (LNS: atomic destroy/repair, once per `mutate()`). Conditions on graph-derived features (`precedenceViolationRate`, `conflictDensity`, `maxChainDepth`) |
| LNS strategy bandit | `LNSStrategyBandit` (`LNSBandit.swift:49`), paired with `LNSRepairBandit` (`LNSBandit.swift:176`) | Picks an LNS destroy/repair strategy adaptively |
| Gene-attention head | `class GeneAttentionHead` (`Sources/Optimizer/GeneticAlgorithm/Operators/ContextualCrossover.swift:67`) | Learned linear scorer over 5 bounded features; reinforcement-style weight updates. Biases crossover toward higher-attention genes |
| RBF surrogate | `RBFSurrogate` in `Optimizer/Fitness/Surrogate.swift` | Predicts fitness for cheap-to-evaluate offspring (see [`fitness-objectives.md`](fitness-objectives.md)) |

LRU cap is `BuboOptimizer.maxCachedLearnerBundles: Int = 8` (`BuboOptimizer.swift:80`). Two `optimize()` calls on the same workload signature reuse the bundle; different workloads get fresh learners.

Additional warm-start hooks (not in the bundle, but global):

- **GNNWarmStart** is a **training-free** small GNN (`enum GNNWarmStart` at `GNNWarmStart.swift:110`, weights `MessagePassingWeights.heuristic` at `:87`) over the conflict / precedence graphs. Produces per-event priority scores for greedy initial seeding. A separate `GNNWarmStartTrainer` (now in its own file at `GNNWarmStartTrainer.swift:21` after the 2026-05-13 split) can refine the weights from observed outcomes via stochastic finite-difference updates.
- **TemporalWarmStart** (in `Reoptimizer/`) seeds from the previous solution when the calendar changes incrementally.

## Quality-diversity

Two separate MAP-Elites archives with different behavior spaces:

- `Optimizer/GeneticAlgorithm/Engine/QualityDiversityArchive.swift` — `struct BehaviorDescriptor` at `:32`. **4D** behavior space (focus, morning skew, day spread, precedence tightness). Used inside evolution to maintain diverse elites.
- `Optimizer/Scenarios/MAPElitesArchive.swift` — `struct MAPElitesArchive` at `:101`. 3D features (`taskSpreadDays`, `morningShare`, `lastTaskHour`) bucketed via `MAPElitesFeatures.cell(bins:)` (`:65`). Used post-GA to back the scenario picker so the user is offered visibly distinct options, not 5 near-duplicates.

## Stopping

`FitnessPlateauDetector.swift` triggers early stopping when improvement stalls. Cancellation is supported when input changes mid-run — see `BuboOptimizer.swift`.

## Diagnostics

`GADebugLog.swift` records evolution telemetry — turn on in `OptimizerTabView` for debugging.

## Outputs

GA → top-K elites → `ScenarioGenerator` → `OptimizerService.scenarios`. The top scenario also feeds `shadowProposal`, still consumed for ghost-slot previews via `BacklogLogic.proposedSlotsFromShadow` (`BacklogScreenModel.swift:169`). Its former one-click-accept chip consumers are both deleted: the main popover's `SmartActionsBar` (PR #582) and the backlog fullscreen's `SmartActions`/`BacklogSmartActionsRow` (PR #584); see [`menu-bar-popover.md`](menu-bar-popover.md).
