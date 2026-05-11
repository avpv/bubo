# Module: Optimizer

> **Kind:** module
> **Sources:** Bubo/Optimizer/
> **Last ingest:** 2026-05-11
> **Related:** [`../concepts/genetic-algorithm.md`](../concepts/genetic-algorithm.md), [`../concepts/fitness-objectives.md`](../concepts/fitness-objectives.md), [`../concepts/intents.md`](../concepts/intents.md), [`tests.md`](tests.md)

## What it does

Given the user's upcoming calendar events, backlog tasks, working-hour preferences, energy curve, Pomodoro rhythm, and a set of declarative intents, the optimizer produces ranked **scenarios** — proposed reschedules. Top scenarios are surfaced to the user as ghost previews and "smart actions".

This is a multi-objective genetic algorithm with adaptive operators, surrogate-assisted fitness, and a quality-diversity archive.

## Layout

```
Optimizer/
├── GACore/        # Generic GA: chromosome, population, selection, crossover, mutation
├── Constraints/   # Hard constraints + conflict graph + caches
├── Fitness/       # Multi-objective fitness, NSGA-III, surrogate
│   └── Objectives/  # ~15 objectives (the "what makes a good schedule" terms)
├── Intents/       # User intent DSL, compiler, NL bridge, conflict detector
├── Learning/      # Preference learner, DPO weight tuning, active sampling
├── Reoptimizer/   # Incremental warm-start on calendar deltas
├── Scenarios/     # MAP-Elites archive + scenario generator
├── Training/      # Offline training coordinator + replay buffer
├── Models/        # Optimizer-internal data types
└── (root)         # AnchorSeeder, AnchorSource
```

## Entry point

`OptimizerService` (in `Services/`) is the public surface — see [`services.md`](services.md). It owns:

- `BuboOptimizer` — the facade at `Bubo/Optimizer/BuboOptimizer.swift` (flat in `Optimizer/`, not under `GACore/`). `@MainActor @Observable final class`. Holds the learner-bundle LRU (default 8 entries, `BuboOptimizer.swift:88`), two graph caches (`IntentGraphSalsaCache`, `ScheduleConflictGraphSalsaCache`), and `lastRunSignature` for routing accept/reject feedback. Default `scenarioCount = 3`. Extensions: `BuboOptimizer+Learning.swift` (flat), `BuboOptimizer+Training.swift` (in `Training/`).
- `IntentLearner` — observes user accept/reject and updates intent weights.
- `lockedEventIds`, `excludedEventIds` — user-driven constraints surfaced from UI.
- `shadowProposal` — current ghost preview the user can accept with one click.

### Concurrency note

Per the doc comment at `BuboOptimizer.swift:165–179`, multiple concurrent `optimize()` calls on the same `BuboOptimizer` are safe. Different workload signatures use disjoint bundles. Same signature shares bandit/head/surrogate — each is lock-protected and individually idempotent (LinUCB updates commute, surrogate samples are independent, head weight updates commute within clamp). The non-determinism is bounded by completion order — same kind of variance the GA tolerates by design.

## GACore key types

Each row verified by reading the file header. `Chromosome` is the abstract genome interface; concrete genomes are `ScheduleChromosome` (declared in `Chromosome.swift`) and `PomodoroSequenceChromosome`.

| File | Main Type | Role |
|---|---|---|
| `Chromosome.swift` | `protocol Chromosome` (`:12`) | Abstract interface — fitness, reproduction, mutation, distance |
| `PomodoroSequenceChromosome.swift` | `struct PomodoroSequenceChromosome` (`:12`) | Task-order permutation within time blocks. Order Crossover (OX1). Energy/deadline-aware fitness |
| `GeneticAlgorithm.swift` | `final class GeneticAlgorithm<C: Chromosome>` (`:404`) | Generic single-population GA engine — selection, crossover, mutation, survivor selection |
| `IslandModelGA.swift` | `final class IslandModelGA<C: Chromosome>` (`:234`) | **Default evolution path.** Multiple parallel populations, periodic migration, optional per-island parameter diversity, adaptive migration. `IslandConfiguration` struct at `:8` |
| `Population.swift` | `struct Population<C: Chromosome>` (`:6`) | Population manager with elitism, parallel evaluation, generation replacement with padding |
| `Selection.swift` | `enum Selection` (`:19`) | Tournament, roulette, rank, stochastic universal sampling. Reproducible RNG threading |
| `Crossover.swift` | `enum Crossover` (`:38`) | Single-point, two-point, uniform, day-block, contextual, graph-aware subtree strategies |
| `ContextualCrossover.swift` | `class GeneAttentionHead` (`:67`) | Learned linear scorer producing per-gene inheritance preferences. 5 bounded features. Reinforcement-style weight updates. Lives in the per-workload `WorkloadLearners` bundle |
| `Mutation.swift` | `enum Mutation` (`:13`) | Standard or adaptive (generation-decaying) mutation rates. Operator-choice logic is in `MutationBandit` |
| `MutationBandit.swift` | `enum MutationOperator` (`:9`) + LinUCB bandit | Five operators (`shift`, `moveDay`, `snap`, `guided`, `lnsDay`). Conditioned on `BanditContext` features |
| `LNSStrategyBandit.swift` | (bandit) | Large-Neighborhood-Search destroy/repair strategy picker |
| `PathRelinking.swift` | `enum PathRelinking` (`:54`) | Post-evolution booster — morphs between elite solutions, evaluates intermediates for improved offspring |
| `SymmetryBreaker.swift` | `enum SymmetryBreaker` (`:36`) | Canonicalizes chromosomes into deterministic order so equivalent schedules hash identically — improves fitness-cache hit rate |
| `TabuMemory.swift` | `final class TabuMemory` (`:25`) | Short-term + long-term tabu memory; tenure-based recency, frequency counters for diversification |
| `CPSATRepair.swift` | `struct CPSATAssignment` (`:74`) | **CDCL-lite solver** with Luby restarts and VSIDS-like activity bumping. Used both for repair and as a construction seed |
| `SlotDomain.swift` | `struct SlotDomain` (`:32`) | Precomputed set of feasible slot indices per movable event. Cached once per run; reused by mutation |
| `SlotRegistry.swift` | `struct SlotRegistry` (`:30`) | Precomputed list of every valid 15-min (or adaptive-stride) start time in the horizon |
| `GARandom.swift` | `final class GARandom` (`:28`) | Seedable deterministic RNG, SplitMix64 backend. Reproducible runs |
| `EvolutionHooks.swift` | `struct EvolutionHooks<C: Chromosome>` (`:30`) | Optional closures fired at evolution events — feeds QD archive, drives gradient refinement |
| `FitnessPlateauDetector.swift` | `struct FitnessPlateauDetector` (`:30`) | Early stopping. Rolling-window relative-stdev test over N generations |
| `QualityDiversityArchive.swift` | `struct BehaviorDescriptor` (`:32`) | **MAP-Elites** archive. 4D behavior: focus, morning skew, day spread, precedence tightness |
| `GADebugLog.swift` | `enum GADebugLog` (`:36`) | Structured GA diagnostics via OSLog — separate warning and trace channels |
| `GNNWarmStart.swift` | `struct MessagePassingWeights` (`:45`) | **Training-free** small GNN over conflict/precedence graphs. Produces per-event priority scores for greedy initial seeding |

## Constraints

| File | Main Type | Role |
|---|---|---|
| `Constraint.swift` | `protocol ScheduleConstraint` (`:8`) | Base protocol. `NoOverlapConstraint` at `:38` uses sweep-based O(N·k) interval overlap; `TaskDependencyConstraint` at `:315` enforces precedence (paired with soft `PrecedenceObjective`) |
| `ConstraintEngine.swift` | `struct ConstraintEngine` (`:6`) | Evaluates all constraints against a chromosome; total penalty + hard feasibility + detailed violation breakdown |
| `ScheduleConflictGraph.swift` | `struct ScheduleConflictGraph` (`:36`) | Indexed conflict/precedence graph; weakly-connected components + transitive precedence + per-day interval indices |
| `ScheduleConflictGraphSalsaCache.swift` | `class` (`:66`) | Salsa-style cache with per-event metadata, per-pair overlap, reachability, whole-graph queries — backed by `QueryDB` |
| `IntentGraphSalsaCache.swift` | `class` (`:55`) | Fine-grained Salsa cache for intent graph build: per-intent compile, per-pair conflict, per-phase bucket, whole-graph |
| `GraphQueryCache.swift` | `class IntentGraphCache` (`:28`) | Older LRU memoization keyed by content hash; retained for tests preferring simpler semantics |
| `QueryDB.swift` | `class QueryDB` (`:78`) | Dependency-tracking memoization DB (Salsa-style); invalidates only affected downstream queries |
| `ReachabilityBitset.swift` | `struct ReachabilityBitset` (`:27`) | Bitset transitive reachability — replaces `[String: Set<String>]` for O(1) precedence queries |
| `ShardedLRUCache.swift` | `class ShardedLRUCache` (`:33`) | 8-shard LRU with `OSAllocatedUnfairLock` per shard. Reduces contention during parallel GA evaluation |

## Fitness

`Fitness/FitnessEvaluator.swift` aggregates the 15+ objectives in `Fitness/Objectives/`. NSGA-III (`NSGA3.swift`) handles many-objective selection. Caches: `FitnessCache`, `ComponentFitnessCache`. Surrogate: `Surrogate.swift` (Gaussian-process style) + `MultiFidelityEvaluator.swift`. `DiffusionRefinement.swift` adds a refinement pass. See [`../concepts/fitness-objectives.md`](../concepts/fitness-objectives.md) for the objective list.

## Intents

`Intents/` is the user-facing knob: declarative intents (e.g. "block 2–5pm", "prioritise X"). Pipeline:

```
NL prompt → LLMIntentBridge → ScheduleIntent → IntentCompiler → constraints + objective weights
                                                              → IntentConflictDetector flags contradictions
                                                              → IntentLearner adapts weights on accept/reject
```

See [`../concepts/intents.md`](../concepts/intents.md).

## Learning

| File | Main Type | Role |
|---|---|---|
| `PreferenceLearner.swift` | `class PreferenceLearner` (`:10`) | Meta-GA over objective weight vectors — evolves weights that best predict observed accept/reject/edit |
| `DPOWeightLearner.swift` | `class DPOWeightLearner` (`:50`) | Direct Preference Optimization. Logistic regression on objective-score deltas to learn per-objective weights from preference feedback |
| `IntentLearner.swift` | `class IntentLearner` (`:16`) | Learns user's intent preferences from accept/reject. Co-occurrence + frequency + temporal patterns of intent combinations |
| `ActiveLearningSampler.swift` | `enum ActiveLearningSampler` (`:34`) | Ranks schedule pairs by information value (entropy × magnitude); surfaces pairs maximizing DPO entropy reduction |
| `CalendarEmbedding.swift` | `class CalendarEmbedder` (`:55`) | 16-dim fixed-length schedule embeddings via transformer-style pooling. Gradient-free contrastive updates |
| `ChanceConstrainedBuffers.swift` | `struct DurationDistribution` (`:25`) | Lognormal duration distribution; CVaR-aware buffers via Welford streaming accumulator. **Privacy-preserving — no raw samples retained** |

## Re-optimizer

| File | Main Type | Role |
|---|---|---|
| `IncrementalReoptimizer.swift` | `class IncrementalReoptimizer` (`:11`) | Mid-day re-optimizer. Freezes past events, seeds GA with current schedule, applies stability penalty, reports improvement only if Δ fitness exceeds threshold |
| `TemporalWarmStart.swift` | `class TemporalWarmStart` (`:35`) | Seeds GA with prior accepted solutions, remapped across days and events via fuzzy matching. Cuts time-to-good-solution 2–3× on recurring calendars |
| `ProactiveReactivePolicy.swift` | `class ProactiveReactivePolicy` (`:54`) | Two-stage recovery for mid-schedule disturbances (delays, cancellations, urgent inserts) — instant corrective edits, avoids full re-opt |

## Scenarios

| File | Main Type | Role |
|---|---|---|
| `MAPElitesArchive.swift` | `struct MAPElitesArchive` (`:79`) | Quality-diversity archive. **5×5×5 = 125 cells** by `(taskSpreadDays, morningShare, lastTaskHour)`. Best-fitness individual per cell. Distinct from GACore's `QualityDiversityArchive` which uses a different 4D behavior space |
| `ScenarioGenerator.swift` | `enum ScenarioComparer` (`:16`) | Compares scenarios against the primary pick; returns human-readable differences (objective deltas, event time shifts > 30 min) |

## Training

Offline preference-learning loop — runs autonomously between optimize calls.

| File | Main Type | Role |
|---|---|---|
| `TrainingCoordinator.swift` | `class TrainingCoordinator` (`:18`) | Orchestrates the pipeline. Collects live events, runs per-learner batches, bootstraps from synthetic pairs on cold start, persists learner state |
| `TrainingReplayBuffer.swift` | `enum TrainingEvent` (`:66`) | Sum type of four event kinds: `preferencePair`, `durationSample`, `branchingDecision`, `embeddingContrast`. Persistent capped JSON-on-disk event store |
| `SyntheticPreferencePairGenerator.swift` | `enum` (`:29`) | Bootstraps DPO/embedder trainers. Generates `(winner, loser)` pairs from the evaluator's own judgement via seeding/perturbation/top-vs-bottom |
| `TrainingPersistence.swift` | `enum TrainingSnapshot` (`:48`) | Codable snapshot covering all trainable learners (DPO, chance buffers, branching bandit). Atomic JSON-on-disk writes |
| `TrainingMetrics.swift` | `class TrainingMetricsLog` (`:39`) | Ring buffer tracking training progress; per round: samples consumed, loss delta, accuracy, per-trainer auxiliary metrics |
| `BuboOptimizer+Training.swift` | `class TrainingState` (`:19`) | Wires the autonomous training pipeline into `BuboOptimizer`'s feedback surface |

## Models

| File | Main Type | Role |
|---|---|---|
| `ScheduleTypes.swift` | `enum Horizon` (`:11`) + others | Shared types: `Horizon`, `Speed`, `Stability`, `Period`, `WeightKey` enums |
| `OptimizerModels.swift` | `struct OptimizableEvent` (`:6`) | Movable event record — ID, duration, priority, context, energy cost, participants, hour range, story points, dependencies, atomicity grouping |
| `TaskSignature.swift` | `struct TaskSignature` (`:28`) | Coarse identity of the optimization workload. Hashes event IDs, 5-min duration buckets, quantized preference weights. **Keys both** the per-workload learner bundle LRU **and** the surrogate/cache state |
| `EventConversion.swift` | `extension CalendarEvent` (`:5`) | `CalendarEvent` → `OptimizableEvent` conversion. Infers focus status, energy cost, Pomodoro config from event metadata |

## Concurrency

GA runs are queued on a background dispatch queue inside `BuboOptimizer`. Results are published back to `@MainActor` via `OptimizerService`. Cancellation is supported when the input changes mid-run.
