# Module: Optimizer

> **Kind:** module
> **Sources:** Sources/Optimizer/, Sources/Optimizer/README.md, Bubo/Application/Intents/, Bubo/Application/Learning/
> **Last ingest:** 2026-05-13 (rev: large-file mechanical splits — `OptimizerModels.swift` deleted, `FitnessEvaluator.swift` / `MutationBandit.swift` / `GNNWarmStart.swift` / `CPSATRepair.swift` shrunk by extracting siblings, and `Chromosome+CPSATSeed.swift` 822→326 split into `Chromosome+SlotSearch.swift` (496 L) for the slot-search helpers shared with init / LNS repair; no symbols moved across module boundaries. Plus `GeneticAlgorithm/` reorganised into six subdirectories — see folder map below.)
> **Related:** [`../concepts/genetic-algorithm.md`](../concepts/genetic-algorithm.md), [`../concepts/fitness-objectives.md`](../concepts/fitness-objectives.md), [`../concepts/intents.md`](../concepts/intents.md), [`../architecture/domain-boundaries.md`](../architecture/domain-boundaries.md), [`../architecture/layered-structure.md`](../architecture/layered-structure.md), [`tests.md`](tests.md)

## What it does

Given the user's upcoming calendar events, backlog tasks, working-hour preferences, energy curve, Pomodoro rhythm, and a set of declarative intents, the optimizer produces ranked **scenarios** — proposed reschedules. Top scenarios are surfaced to the user as ghost previews and "smart actions".

This is a multi-objective genetic algorithm with adaptive operators, surrogate-assisted fitness, and a quality-diversity archive.

## Layout

```
Optimizer/
├── Anchors/           # AnchorSeeder, AnchorSource (split out of root)
├── Constraints/       # Hard constraints + conflict graph + caches
├── Orchestrator/      # BuboOptimizer facade + +Diagnostics / +Feedback / +Learning /
│                      # +SpecializedPlanning / +Aliases / +Reoptimization / +Training extensions
│                      # (771-line core + 6 sibling files after 2026-05-12 split).
│                      # Renamed from `Core/` on 2026-05-12 to disambiguate from GeneticAlgorithm/.
├── Fitness/           # Multi-objective fitness, NSGA-III, surrogate
│   └── Objectives/    # ~15 objectives (the "what makes a good schedule" terms)
├── GeneticAlgorithm/  # Generic GA. Renamed from `GACore/` on 2026-05-12.
│   │                  # Subdivided 2026-05-13 into 6 directories (was 47 flat files):
│   ├── Core/          # Chromosome, ChromosomeProtocol, PomodoroSequenceChromosome, Population,
│   │                  # GAConfiguration, GARandom, GADebugLog, MultiObjectiveContext,
│   │                  # ScheduleHorizonHelpers, SlotDomain, SlotRegistry (11 files)
│   ├── Operators/     # Selection, Crossover, ContextualCrossover, Mutation, SymmetryBreaker,
│   │                  # Chromosome+Initialization/Crossover/Mutation/Distance (9 files)
│   ├── Repair/        # CPSATRepair, CPSATAtoms, Chromosome+Repair/CPRepair/CPSATRepair/
│   │                  # CPSATSeed/RegretRepair (7 files)
│   ├── Adaptive/      # MutationBandit, LNSBandit, Chromosome+LNSDestroy,
│   │                  # GeneticAlgorithm+BanditFeatures, TabuMemory (5 files)
│   ├── IslandModel/   # IslandModelGA + (Configurations/Diversity/Migration), IslandConfiguration,
│   │                  # PathRelinking (6 files)
│   └── Engine/        # GeneticAlgorithm + EvolutionHelpers, EvolutionHooks, ComponentFitnessCache,
│                      # QualityDiversityArchive, FitnessPlateauDetector,
│                      # DifferentiableRelaxation, GNNWarmStart + Trainer (9 files)
├── Learning/      # Pure adaptive pieces: DPO weight tuning, active sampling,
│                  # calendar embedding, chance-constrained buffers, and
│                  # PreferenceLearner (meta-GA weight evolution; PR #516
│                  # moved the core class back here from Application/Learning/;
│                  # its CloudSync bridge extension remains in Bubo/Application/
│                  # Learning/PreferenceLearner.swift).
│                  # IntentLearner remains in Application/Learning/.
├── Reoptimizer/   # Incremental warm-start on calendar deltas
├── Scenarios/     # MAP-Elites archive + scenario generator
├── Training/      # Offline training coordinator + replay buffer (incl. BuboOptimizer+Training)
└── Models/        # Optimizer-internal data types — see domain-boundaries.md.
                   # On 2026-05-12 Period, PomodoroConfig, and
                   # OptimizableEvent moved out of here into BuboDomain
                   # (Calendar/ and Pomodoro/) — they were referenced by
                   # CalendarEvent/BacklogTask, which produced a Domain↔
                   # Optimizer cycle. The breadcrumb comments at the top
                   # of `ScheduleGene.swift` (the file that inherited
                   # the breadcrumb on 2026-05-13 when the 676-line
                   # `OptimizerModels.swift` was split into per-type
                   # files: `ScheduleGene.swift`, `OptimizerContext.swift`,
                   # `OptimizerPreferences.swift`, `OptimizerResult.swift`)
                   # and `ScheduleTypes.swift` point at the new homes.
```

`BuboOptimizer` is its own SwiftPM target as of 2026-05-12, depending only on `BuboDomain` (which holds `CalendarEvent`, `BacklogTask`, `Period`, `PomodoroConfig`, `OptimizableEvent`, etc.). No dependency on the `Bubo` executable target, so the Application/Presentation/Composition/Infrastructure layers can't leak back in at compile time. See [`../architecture/layered-structure.md`](../architecture/layered-structure.md) for the full target graph.

The folder-level boundary rules are also restated inline in
`Sources/Optimizer/README.md` — peer-of-Domain placement rationale, the
per-subfolder responsibility map, and the no-EventKit / no-SwiftUI
import rule for every engine file. The README is excluded from the
SPM build via `Package.swift`.

## Entry point

`OptimizerService` (in `Application/`) is the public surface — see [`services.md`](services.md). It owns:

- `BuboOptimizer` — the facade at `Sources/Optimizer/Orchestrator/BuboOptimizer.swift`. `@MainActor @Observable final class`. Inner `final class WorkloadLearners` bundles `MutationBandit`, `LNSStrategyBandit`, `GeneAttentionHead`, `RBFSurrogate`. Holds the per-signature learner-bundle LRU (`maxCachedLearnerBundles: Int = 8`), one graph cache `conflictGraphCache: ScheduleConflictGraphSalsaCache` (`:131`), `preferenceLearner: PreferenceLearner` (`:26`), and `lastRunSignature` for routing accept/reject feedback. `IntentGraphSalsaCache` moved to `Bubo/Application/Intents/Graph/` in PR #516 and is now a shared singleton there. The original 1974-line file is now 771 L of core + 7 extension files: `BuboOptimizer+Diagnostics.swift`, `BuboOptimizer+SpecializedPlanning.swift`, `BuboOptimizer+Feedback.swift`, `BuboOptimizer+Learning.swift`, `BuboOptimizer+Aliases.swift` (thin wrappers `optimizeWithPareto`/`optimizeToday`/`optimizeWeek` + `workloadDifficulty`, added 2026-05-12), `BuboOptimizer+Reoptimization.swift` (`reoptimize`/`instantReflow` + private `makeReoptContext`, added 2026-05-12), and `BuboOptimizer+Training.swift` (under `Training/`).
- `IntentLearner` — observes user accept/reject and updates intent weights.
- `lockedEventIds`, `excludedEventIds` — user-driven constraints surfaced from UI.
- `shadowProposal` — current ghost preview the user can accept with one click.

### Concurrency note

Per the doc comment near the top of `Orchestrator/BuboOptimizer.swift`, multiple concurrent `optimize()` calls on the same `BuboOptimizer` are safe. Different workload signatures use disjoint bundles. Same signature shares bandit/head/surrogate — each is lock-protected and individually idempotent (LinUCB updates commute, surrogate samples are independent, head weight updates commute within clamp). The non-determinism is bounded by completion order — same kind of variance the GA tolerates by design.

## GeneticAlgorithm/ key types

Each row verified by reading the file header. `Chromosome` is the abstract genome interface; concrete genomes are `ScheduleChromosome` (declared in `Core/Chromosome.swift`) and `PomodoroSequenceChromosome` (in `Core/`). File names below are unqualified — see the folder map above for which subdirectory (`Core/`, `Operators/`, `Repair/`, `Adaptive/`, `IslandModel/`, `Engine/`) each one lives in after the 2026-05-13 reorganisation.

| File | Main Type | Role |
|---|---|---|
| `Chromosome.swift` + 13 siblings | `struct ScheduleChromosome` | The 3487-line original was decomposed (95% smaller): `Chromosome.swift` (~159 L) keeps the struct declaration + stored properties + Equatable/Hashable; behaviour lives in `ChromosomeProtocol.swift` (the `Chromosome` protocol + default impls), `Chromosome+Initialization.swift` (random/greedy + private helpers), `Chromosome+Crossover.swift` (order-based + `makeChild`), `Chromosome+Mutation.swift` (mutate + LNS dispatch), `Chromosome+Repair.swift` (guided helpers + repair pass), `Chromosome+CPSATSeed.swift` (the `cpSeeded` entry point only — 326 L after the 2026-05-13 split), `Chromosome+SlotSearch.swift` (the four slot-search helpers split out 2026-05-13 — `findFirstFreeSlot`, `findLastFreeSlot`, `enumerateFeasibleSlots`, `OccupiedInterval`, all `public static`, no visibility change), `Chromosome+CPSATRepair.swift` (CP-SAT bridge `applyCPSATRepair` + private `candidateStartTimes`), `Chromosome+LNSDestroy.swift` (`destroy` strategy operator, added 2026-05-12), `Chromosome+CPRepair.swift` (handwritten CP-SAT-lite `cpRepair` branch-and-bound, added 2026-05-12), `Chromosome+RegretRepair.swift` (regret-based `regretRepair` fallback, added 2026-05-12), `Chromosome+Distance.swift` (SIMD genotypic distance), and the file-scope `ScheduleHorizonHelpers.swift` (advancePastNonWorkingDay/clampToWorkingHours). Visibility relaxations documented inline at each cross-file callee. |
| `PomodoroSequenceChromosome.swift` | `struct PomodoroSequenceChromosome` (`:12`) | Task-order permutation within time blocks. Order Crossover (OX1). Energy/deadline-aware fitness |
| `GeneticAlgorithm.swift` + 4 siblings | `final class GeneticAlgorithm<C: Chromosome>` | The 1235-line original is now 633 L of engine class + 4 sibling files: `GAConfiguration.swift` (the 325-line config struct with named presets), `MultiObjectiveContext.swift` (NSGA-III hookup), `GeneticAlgorithm+EvolutionHelpers.swift` (CHC restart, memetic hill climb, SA-hybrid `hillClimb`), `GeneticAlgorithm+BanditFeatures.swift` (`graphBanditFeatures` and `objectiveImbalance` for `MutationBandit` context). `evaluate`, `multiObjective`, `GraphBanditFeatures` visibility relaxed to internal so extensions can read them. |
| `IslandModelGA.swift` + 4 siblings | `final class IslandModelGA<C: Chromosome>` | **Default evolution path.** The 1160-line original is now 612 L of engine class + 4 sibling files: `IslandConfiguration.swift` (the top-level Sendable value types — `IslandConfiguration` + `MigrationTopology` / `EmigrantSelection` / `ImmigrantReplacement` enums + `CrossIslandDiversity` / `IslandModelProgress`), `IslandModelGA+Configurations.swift` (`makeIslandConfigs` per-island GA-configuration generator), `IslandModelGA+Migration.swift` (the migrate/destroy/select-emigrants/insert-immigrants pipeline incl. Pareto-aware emigrant selection), `IslandModelGA+Diversity.swift` (`measureCrossIslandDiversity` for adaptive migration). The internal `Island<C>` helper class is now internal (was file-private) so the +Migration file can name it. |
| `Population.swift` | `struct Population<C: Chromosome>` (`:6`) | Population manager with elitism, parallel evaluation, generation replacement with padding |
| `Selection.swift` | `enum Selection` (`:19`) | Tournament, roulette, rank, stochastic universal sampling. Reproducible RNG threading |
| `Crossover.swift` | `enum Crossover` (`:38`) | Single-point, two-point, uniform, day-block, contextual, graph-aware subtree strategies |
| `ContextualCrossover.swift` | `class GeneAttentionHead` (`:67`) | Learned linear scorer producing per-gene inheritance preferences. 5 bounded features. Reinforcement-style weight updates. Lives in the per-workload `WorkloadLearners` bundle |
| `Mutation.swift` | `enum Mutation` (`:13`) | Standard or adaptive (generation-decaying) mutation rates. Operator-choice logic is in `MutationBandit` |
| `MutationBandit.swift` + `LNSBandit.swift` | `enum MutationOperator` (`MutationBandit.swift:9`), `class MutationBandit` (`MutationBandit.swift:134`), `class LNSStrategyBandit` (`LNSBandit.swift:49`), `class LNSRepairBandit` (`LNSBandit.swift:176`), `protocol AdaptiveMutationChromosome` (`LNSBandit.swift:264`) | Five operators (`shift`, `moveDay`, `snap`, `guided`, `lnsDay`) over LinUCB. `LNSStrategyBandit` picks the destroy strategy for LNS, `LNSRepairBandit` mirrors that for repair heuristics. All conditioned on `BanditContext` (`MutationBandit.swift:54`) features. `MutationBandit.swift` split into mutation-side (427 L, this file) + LNS-side (`LNSBandit.swift`, 268 L) on 2026-05-13 — `LNSDestroyStrategy` / `LNSRepairStrategy` enums and the two LNS bandits moved into the sibling |
| `DifferentiableRelaxation.swift` | `struct ScheduleGradientRefiner` (`:30`) | Differentiable relaxation of the schedule for gradient-based post-GA refinement of soft fitness terms |
| `PathRelinking.swift` | `enum PathRelinking` (`:54`) | Post-evolution booster — morphs between elite solutions, evaluates intermediates for improved offspring |
| `SymmetryBreaker.swift` | `enum SymmetryBreaker` (`:36`) | Canonicalizes chromosomes into deterministic order so equivalent schedules hash identically — improves fitness-cache hit rate |
| `TabuMemory.swift` | `final class TabuMemory` (`:25`) | Short-term + long-term tabu memory; tenure-based recency, frequency counters for diversification |
| `CPSATRepair.swift` + `CPSATAtoms.swift` | `struct CPVariable` (`CPSATAtoms.swift:50`), `struct NoGoodClause` (`CPSATAtoms.swift:74`), `struct CPSATAssignment` (`CPSATAtoms.swift:103`), `final class CPSATRepairer` (`CPSATRepair.swift:5`) | **CDCL-lite solver** with Luby restarts and VSIDS-like activity bumping. Used both for repair and as a construction seed. The 745-line file split 2026-05-13 — value types (`CPVariable` / `NoGoodClause` / `CPSATAssignment`) into `CPSATAtoms.swift`, the `CPSATRepairer` engine remained in `CPSATRepair.swift` |
| `SlotDomain.swift` | `struct SlotDomain` (`:32`) | Precomputed set of feasible slot indices per movable event. Cached once per run; reused by mutation |
| `SlotRegistry.swift` | `struct SlotRegistry` (`:30`) | Precomputed list of every valid 15-min (or adaptive-stride) start time in the horizon |
| `GARandom.swift` | `final class GARandom` (`:28`) | Seedable deterministic RNG, SplitMix64 backend. Reproducible runs |
| `EvolutionHooks.swift` | `struct EvolutionHooks<C: Chromosome>` (`:30`) | Optional closures fired at evolution events — feeds QD archive, drives gradient refinement |
| `FitnessPlateauDetector.swift` | `struct FitnessPlateauDetector` (`:30`) | Early stopping. Rolling-window relative-stdev test over N generations |
| `QualityDiversityArchive.swift` | `struct BehaviorDescriptor` (`:32`) | **MAP-Elites** archive. 4D behavior: focus, morning skew, day spread, precedence tightness |
| `GADebugLog.swift` | `enum GADebugLog` (`:36`) | Structured GA diagnostics via OSLog — separate warning and trace channels |
| `GNNWarmStart.swift` + `GNNWarmStartTrainer.swift` | `struct GNNNodeFeatures` (`GNNWarmStart.swift:29`), `struct MessagePassingWeights` (`GNNWarmStart.swift:63`), `enum GNNWarmStart` (`GNNWarmStart.swift:110`), `final class GNNWarmStartTrainer` (`GNNWarmStartTrainer.swift:21`) | **Training-free** small GNN over conflict/precedence graphs. Produces per-event priority scores for greedy initial seeding. The optional online `GNNWarmStartTrainer` (refines weights from observed outcomes via stochastic finite differences) split into its own file 2026-05-13 |

## Constraints

| File | Main Type | Role |
|---|---|---|
| `Constraint.swift` | `protocol ScheduleConstraint` (`:8`) | Base protocol. `NoOverlapConstraint` at `:38` uses sweep-based O(N·k) interval overlap; `TaskDependencyConstraint` at `:315` enforces precedence (paired with soft `PrecedenceObjective`) |
| `ConstraintEngine.swift` | `struct ConstraintEngine` (`:6`) | Evaluates all constraints against a chromosome; total penalty + hard feasibility + detailed violation breakdown |
| `ScheduleConflictGraph.swift` | `struct ScheduleConflictGraph` (`:36`) | Indexed conflict/precedence graph; weakly-connected components + transitive precedence + per-day interval indices |
| `ScheduleConflictGraphSalsaCache.swift` | `class` (`:66`) | Salsa-style cache with per-event metadata, per-pair overlap, reachability, whole-graph queries — backed by `QueryDB` |
| `GraphQueryCache.swift` | `class IntentGraphCache` (`:28`) | Older LRU memoization keyed by content hash; retained for tests preferring simpler semantics |
| `QueryDB.swift` | `class QueryDB` (`:78`) | Dependency-tracking memoization DB (Salsa-style); invalidates only affected downstream queries |
| `ReachabilityBitset.swift` | `struct ReachabilityBitset` (`:27`) | Bitset transitive reachability — replaces `[String: Set<String>]` for O(1) precedence queries |
| `ShardedLRUCache.swift` | `class ShardedLRUCache` (`:33`) | 8-shard LRU with `OSAllocatedUnfairLock` per shard. Reduces contention during parallel GA evaluation |

## Fitness

`Fitness/FitnessEvaluator.swift` (712 L of `class FitnessEvaluator`) aggregates the 15+ objectives in `Fitness/Objectives/`. NSGA-III (`NSGA3.swift`) handles many-objective selection. Caches: `FitnessCache`, `ComponentFitnessCache`. Surrogate: `Surrogate.swift` (Gaussian-process style) + `MultiFidelityEvaluator.swift`. `DiffusionRefinement.swift` adds a refinement pass. The 961-line monolith was split 2026-05-13 — sharded eval counters went to `Fitness/FitnessEvalTelemetry.swift` (133 L, `final class FitnessEvalTelemetry`), the three protocols (`FitnessObjective`, `DayPartitionedObjective`, `ComponentPartitionedObjective`) went to `Fitness/FitnessObjective.swift` (120 L). See [`../concepts/fitness-objectives.md`](../concepts/fitness-objectives.md) for the objective list.

## Intents (lives in Application/, not Optimizer/)

`Application/Intents/` is the user-facing knob: declarative intents (e.g. "block 2–5pm", "prioritise X"). It moved out of `Optimizer/` on 2026-05-12 because the compilers depend on `ReminderService`, `BacklogService`, `EnergyCheckInService`, `PomodoroHistoryService`, and `OptimizerService` — application-layer services. Optimizer code itself only sees the compiled `OptimizationRequest` value type.

The directory is split by role:

```
Application/Intents/
├── ScheduleIntent.swift          # core value type — the IR all stages consume
├── IntentPresets.swift           # built-in intent libraries
├── Compiler/                     # IntentCompiler + four sibling extension files
├── Graph/                        # IntentGraph (DAG model) + Phase/Rules/Advanced
├── Engines/                      # SuggestionEngine, TriggerEngine, QuickActionRanker
├── Rules/                        # IntentConflictDetector, PomodoroConfigResolver, BacklogTaskCohesion
└── Bridges/                      # LLMIntentBridge (DeepSeek function-calling)
```

Pipeline:

```
NL prompt → LLMIntentBridge → ScheduleIntent → IntentCompiler → constraints + objective weights
                                                              → IntentConflictDetector flags contradictions
                                                              → IntentLearner adapts weights on accept/reject
```

See [`../concepts/intents.md`](../concepts/intents.md).

The 1519-line `IntentCompiler.swift` original is now 278 L (the `execute(...)` entry point + `buildCapacityResolutions`) plus four sibling files split along the pipeline stages: `IntentCompiler+Apply.swift` (`ResolvedConfig` IR + per-intent application logic + condition eval + auto-pomodoro resolver), `IntentCompiler+EventCollection.swift` (synthetic/local/backlog event materialisation + source filters + event rules + post-transforms), `IntentCompiler+Preferences.swift` (`ResolvedConfig → OptimizerPreferences` translation), `IntentCompiler+Horizon.swift` (Horizon resolution + pre-flight capacity check + backlog cap + `ScheduleSnapshot` builder). The four originally-`private extension` blocks were promoted to plain `extension` so the cross-file split works.

The 977-line `IntentGraph.swift` original is now 725 L (graph builder + reachability + topological sort + conflict detection) plus two sibling files: `IntentGraph+Rules.swift` (static rules catalog: `phase(for:)`, `dependencies(for:)`, `suggestions(for:)`, `conflictReason(_:_:)`, `allKnownIntents`) and `IntentGraph+Phase.swift` (the `Phase.displayName` localised labels).

## Learning

Split across two folders by dependency profile:

`Optimizer/Learning/` — pure adaptive pieces with no service deps:

| File | Main Type | Role |
|---|---|---|
| `DPOWeightLearner.swift` | `class DPOWeightLearner` (`:50`) | Direct Preference Optimization. Logistic regression on objective-score deltas to learn per-objective weights from preference feedback |
| `ActiveLearningSampler.swift` | `enum ActiveLearningSampler` (`:34`) | Ranks schedule pairs by information value (entropy × magnitude); surfaces pairs maximizing DPO entropy reduction |
| `CalendarEmbedding.swift` | `class CalendarEmbedder` (`:55`) | 16-dim fixed-length schedule embeddings via transformer-style pooling. Gradient-free contrastive updates |
| `ChanceConstrainedBuffers.swift` | `struct DurationDistribution` (`:25`) | Lognormal duration distribution; CVaR-aware buffers via Welford streaming accumulator. **Privacy-preserving — no raw samples retained** |
| `PreferenceLearner.swift` | `public final class PreferenceLearner` (`:11`) | Meta-GA over objective weight vectors — evolves weights that best predict user accept/reject/edit. Owned by `BuboOptimizer` as `preferenceLearner`. Persists weights and feedback history via `UserDefaults`. No CloudSync or service deps in this file. |

`Application/Learning/` — history-based learners or cloud-sync bridges:

| File | Main Type | Role |
|---|---|---|
| `PreferenceLearner.swift` | `extension PreferenceLearner` | Cloud-sync bridge (PR #516). Adds `setupCloudSync()` (idempotent `NotificationCenter` observer wired to `CloudSyncService.didReceiveRemoteChange`) and `pushToCloudSync()`. Core class lives in `Sources/Optimizer/Learning/`. |
| `IntentLearner.swift` | `class IntentLearner` (`:16`) | Learns user's intent preferences from accept/reject. Co-occurrence + frequency + temporal patterns of intent combinations. Pushes/restores via CloudKit on changes |

## Re-optimizer

| File | Main Type | Role |
|---|---|---|
| `IncrementalReoptimizer.swift` | `class IncrementalReoptimizer` (`:11`) | Mid-day re-optimizer. Freezes past events, seeds GA with current schedule, applies stability penalty, reports improvement only if Δ fitness exceeds threshold |
| `TemporalWarmStart.swift` | `class TemporalWarmStart` (`:35`) | Seeds GA with prior accepted solutions, remapped across days and events via fuzzy matching. Cuts time-to-good-solution 2–3× on recurring calendars |
| `ProactiveReactivePolicy.swift` | `class ProactiveReactivePolicy` (`:54`) | Two-stage recovery for mid-schedule disturbances (delays, cancellations, urgent inserts) — instant corrective edits, avoids full re-opt |

## Scenarios

| File | Main Type | Role |
|---|---|---|
| `MAPElitesArchive.swift` | `struct MAPElitesArchive` (`:79`) | Quality-diversity archive. **5×5×5 = 125 cells** by `(taskSpreadDays, morningShare, lastTaskHour)`. Best-fitness individual per cell. Distinct from `GeneticAlgorithm/`'s `QualityDiversityArchive` which uses a different 4D behavior space |
| `ScenarioGenerator.swift` | `enum ScenarioComparer` (`:16`) | Compares scenarios against the primary pick; returns human-readable differences (objective deltas, event time shifts > 30 min) |

## Training

Offline preference-learning loop — runs autonomously between optimize calls. Header at `BuboOptimizer+Training.swift:3–17` describes the cadence: no internal timer, training cycle runs on demand via `runTrainingCycle(...)`. Host typically calls it on app backgrounding, after every N accepts (`trainingAcceptCadence: Int { 8 }` at `:71`), or on explicit "Improve model now" action.

| File | Main Type | Role |
|---|---|---|
| `TrainingCoordinator.swift` | `class TrainingCoordinator` (`:18`) | Orchestrates the pipeline. Collects live events, runs per-learner batches, bootstraps from synthetic pairs on cold start, persists learner state |
| `TrainingReplayBuffer.swift` | `enum TrainingEvent` (`:66`) | Sum type of four event kinds: `preferencePair`, `durationSample`, `branchingDecision`, `embeddingContrast`. Persistent capped JSON-on-disk event store |
| `SyntheticPreferencePairGenerator.swift` | `enum` (`:29`) | Bootstraps DPO/embedder trainers. Generates `(winner, loser)` pairs from the evaluator's own judgement via seeding/perturbation/top-vs-bottom |
| `TrainingPersistence.swift` | `struct TrainingSnapshot` (`:48`) + `enum TrainingPersistence` (`:55`) | Codable snapshot covering all trainable learners (DPO, chance buffers, branching bandit). Atomic JSON-on-disk save/load (`:69`, `:79`) |
| `TrainingMetrics.swift` | `class TrainingMetricsLog` (`:39`) | Ring buffer tracking training progress; per round: samples consumed, loss delta, accuracy, per-trainer auxiliary metrics |
| `BuboOptimizer+Training.swift` | `fileprivate class TrainingState` (`:19`) | Wires the training pipeline into `BuboOptimizer`. Uses a `TrainingStateStore` keyed by `ObjectIdentifier(self)` so each BuboOptimizer instance has its own training state. Public surface: `trainingReplayBuffer`, `trainingMetrics`, `trainingAcceptCadence`, `trainingRecordAccept(accepted:runnerUps:)` |

## Adaptive feature toggles (`BuboOptimizer+Learning.swift`)

616-line extension. The header at `:3–18` is explicit: defaults enable the **safe, low-risk, strictly additive** subset; heavier changes default off.

`struct SchedulingFeatureToggles` (`:21`) — single source of truth for which adaptive subsystems are active:

| Toggle | Wave | Default | What |
|---|---|---|---|
| `useLexicographicRanking` | 1 | on | Lex-fitness hierarchy when ranking scenarios; precedence/conflict dominate soft objectives |
| `useSymmetryBreaking` | 1 | on | Canonicalises gene order after mutation; boosts cache hit rate and determinism |
| `useTabuMemory` | 1 | on | Tabu list + long-term frequency diversification on LNS moves; per-workload |
| `useTemporalWarmStart` | 1 | on | Reuse prior accepted solution as warm-start seed |
| `useMultiFidelityFunnel` | 1 | on | Tier-1 surrogate funnel over batch evaluations |
| `useObjectiveClustering` | 2 | on | Online objective-correlation clustering; surfaced via telemetry |
| `usePathRelinking` | 2 | on | Post-GA path relinking across final scenarios |
| `useCPSATSeed` | — | on | Inject `CPSATRepairer` so `ScheduleChromosome.cpSeeded` produces one feasibility-optimal construction seed per run. On timeout or infeasibility returns nil and warm-start collector skips it |
| `cpSATWindowThreshold` | — | 20 | Decides when CPSAT construction seeder fires at all |

**Removed flags (history at `:62–77`):** `useMOEADAWASurvivor` (alternative NSGA-III replacement), `useCMAMEEmitter` (covariance-adapted Gaussian emitter over MAP-Elites), `useLearnedBranching` (LinUCB bandit over CPSAT variable selection), `useCPSATRepair` (routed LNS destroy windows through the CDCL-lite solver — handwritten branch-and-bound matched it on realistic workloads as a *repair* engine; the same `CPSATRepair.swift` solver now lives on as the *seeder* backend via `useCPSATSeed`).

Methods on `BuboOptimizer` declared here:

| Method | Line | Role |
|---|---|---|
| `obtainLearnerSuite(for:)` | `:191` | Adaptive-learner bundle obtained per workload |
| `lookupLearnerSuite(for scenario:)` | `:209` | Find the bundle that produced a given scenario |
| `propagateAcceptFeedback(...)` | `:228` | Push user-accept feedback into the learners |
| `recordPreferencePair(...)` | `:292` | Add a `(winner, loser)` to the replay buffer |
| `recordEventDurationSample(...)` | `:309` | Append a duration observation for chance-buffer learning |
| `reactToDisturbance(...)` | `:330` | Mid-schedule disturbance recovery (delays, cancellations) |
| `adjustPreferencesFromLearners(...)` | `:395` | Apply learner output to objective weights |
| `collectWarmStartSeeds(context:)` | `:408` | Build initial population seeds (incl. temporal + GNN + greedy) |
| `refineAndRankScenarios(...)` | `:497` | Post-GA refinement + lex ranking |

## Models

| File | Main Type | Role |
|---|---|---|
| `ScheduleTypes.swift` | `enum Horizon` (`:11`) + others | Shared types: `Horizon`, `Speed`, `Stability`, `Period`, `WeightKey` enums |
| `ScheduleGene.swift` | `struct ScheduleGene` (`:17`) | A single gene: placement of one event in the schedule. Inherits the breadcrumb explaining where `OptimizableEvent` / `PomodoroConfig` went (Domain) |
| `OptimizerContext.swift` | `struct OptimizerContext` (`:11`) | The frozen input snapshot the GA optimizes against — events, backlog, working hours, energy curve, intent-compiled constraints |
| `OptimizerPreferences.swift` | `struct OptimizerPreferences` (`:7`) | Per-objective weights + structural knobs (`workingDays`, `defaultBufferMinutes`, …). Init at `:120` carries the default values |
| `OptimizerResult.swift` | `struct OptimizerResult` (`:4`), `struct ScheduleScenario` (`:18`), `struct OptimizationMetadata` (`:86`), `enum UserFeedback` (`:112`) | Output of one GA run — top scenarios + Pareto front + diagnostic metadata + the feedback enum for accept/reject signalling |
| `TaskSignature.swift` | `struct TaskSignature` (`:28`) | Coarse identity of the optimization workload. Hashes event IDs, 5-min duration buckets, quantized preference weights. **Keys both** the per-workload learner bundle LRU **and** the surrogate/cache state |
| `EventConversion.swift` | `extension CalendarEvent` (`:5`) | `CalendarEvent` → `OptimizableEvent` conversion. Infers focus status, energy cost, Pomodoro config from event metadata |

The four type-per-file rows above are the result of splitting the
676-line `OptimizerModels.swift` (deleted on 2026-05-13) — no symbols
moved across modules, only across sibling files within
`Sources/Optimizer/Models/`. The earlier breadcrumb explaining where
`OptimizableEvent` and `PomodoroConfig` went (to `Sources/Domain/` on
2026-05-12) now sits at the top of `ScheduleGene.swift`.

## Concurrency

GA runs are queued on a background dispatch queue inside `BuboOptimizer`. Results are published back to `@MainActor` via `OptimizerService`. Cancellation is supported when the input changes mid-run.
