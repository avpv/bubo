# Module: Optimizer

> **Kind:** module
> **Sources:** Sources/BuboOptimizer/, Sources/BuboOptimizer/README.md, Bubo/Application/Intents/, Bubo/Application/Learning/
> **Last ingest:** 2026-05-12 (rev: fixed stale Models table — ScheduleGene is now the lead type in OptimizerModels.swift; Period removed from ScheduleTypes list; both moved to BuboDomain. GeneticAlgorithm key types table moved to genetic-algorithm.md)
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
├── GeneticAlgorithm/  # Generic GA: chromosome, population, selection, crossover, mutation,
│                      # IslandModelGA, GAConfiguration. Chromosome split into 12 sibling files
│                      # (ChromosomeProtocol + +Initialization/+Crossover/+Mutation/+Repair/
│                      # +CPSATSeed/+CPSATRepair/+LNSDestroy/+CPRepair/+RegretRepair/+Distance +
│                      # ScheduleHorizonHelpers free funcs); IslandModelGA split into 4 sibling
│                      # files; GeneticAlgorithm split into 3.
│                      # Renamed from `GACore/` on 2026-05-12.
├── Learning/      # Pure adaptive pieces: DPO weight tuning, active sampling,
│                  # calendar embedding, chance-constrained buffers.
│                  # History-based learners (IntentLearner, PreferenceLearner)
│                  # moved to Application/Learning/ on 2026-05-12 because they
│                  # depend on CloudSyncService.
├── Reoptimizer/   # Incremental warm-start on calendar deltas
├── Scenarios/     # MAP-Elites archive + scenario generator
├── Training/      # Offline training coordinator + replay buffer (incl. BuboOptimizer+Training)
└── Models/        # Optimizer-internal data types — see domain-boundaries.md.
                   # On 2026-05-12 Period, PomodoroConfig, and
                   # OptimizableEvent moved out of here into BuboDomain
                   # (Calendar/ and Pomodoro/) — they were referenced by
                   # CalendarEvent/BacklogTask, which produced a Domain↔
                   # Optimizer cycle. The breadcrumb comments at the top
                   # of `OptimizerModels.swift` and `ScheduleTypes.swift`
                   # point at the new homes.
```

`BuboOptimizer` is its own SwiftPM target as of 2026-05-12, depending only on `BuboDomain` (which holds `CalendarEvent`, `BacklogTask`, `Period`, `PomodoroConfig`, `OptimizableEvent`, etc.). No dependency on the `Bubo` executable target, so the Application/Presentation/Composition/Infrastructure layers can't leak back in at compile time. See [`../architecture/layered-structure.md`](../architecture/layered-structure.md) for the full target graph.

Boundary rules and import restrictions are also restated in `Sources/BuboOptimizer/README.md` (excluded from SPM build via `Package.swift`).

## Entry point

`OptimizerService` (in `Application/`) is the public surface — see [`services.md`](services.md). It owns:

- `BuboOptimizer` — the facade at `Sources/BuboOptimizer/Orchestrator/BuboOptimizer.swift`. `@MainActor @Observable final class`. Inner `final class WorkloadLearners` bundles `MutationBandit`, `LNSStrategyBandit`, `GeneAttentionHead`, `RBFSurrogate`. Holds the per-signature learner-bundle LRU (`maxCachedLearnerBundles: Int = 8`), two graph caches `intentGraphCache: IntentGraphSalsaCache` and `conflictGraphCache: ScheduleConflictGraphSalsaCache`, and `lastRunSignature` for routing accept/reject feedback. The original 1974-line file is now 771 L of core + 7 extension files: `BuboOptimizer+Diagnostics.swift`, `BuboOptimizer+SpecializedPlanning.swift`, `BuboOptimizer+Feedback.swift`, `BuboOptimizer+Learning.swift`, `BuboOptimizer+Aliases.swift` (thin wrappers `optimizeWithPareto`/`optimizeToday`/`optimizeWeek` + `workloadDifficulty`, added 2026-05-12), `BuboOptimizer+Reoptimization.swift` (`reoptimize`/`instantReflow` + private `makeReoptContext`, added 2026-05-12), and `BuboOptimizer+Training.swift` (under `Training/`).
- `IntentLearner` — observes user accept/reject and updates intent weights.
- `lockedEventIds`, `excludedEventIds` — user-driven constraints surfaced from UI.
- `shadowProposal` — current ghost preview the user can accept with one click.

### Concurrency note

Per the doc comment near the top of `Orchestrator/BuboOptimizer.swift`, multiple concurrent `optimize()` calls on the same `BuboOptimizer` are safe. Different workload signatures use disjoint bundles. Same signature shares bandit/head/surrogate — each is lock-protected and individually idempotent (LinUCB updates commute, surrogate samples are independent, head weight updates commute within clamp). The non-determinism is bounded by completion order — same kind of variance the GA tolerates by design.

## GeneticAlgorithm/ key types

See [`../concepts/genetic-algorithm.md`](../concepts/genetic-algorithm.md) for the per-file type and role breakdown of `ScheduleChromosome`, `IslandModelGA`, `GeneticAlgorithm`, and the 20+ supporting types.

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

## Intents (lives in Application/, not Optimizer/)

`Application/Intents/` is the user-facing knob: declarative intents (e.g. "block 2–5pm", "prioritise X"). It moved out of `Optimizer/` on 2026-05-12 because the compilers depend on `ReminderService`, `BacklogService`, `EnergyCheckInService`, `PomodoroHistoryService`, and `OptimizerService` — application-layer services. Optimizer code itself only sees the compiled `OptimizationRequest` value type.

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

`Sources/BuboOptimizer/Learning/` — pure adaptive pieces with no service deps:

| File | Main Type | Role |
|---|---|---|
| `DPOWeightLearner.swift` | `class DPOWeightLearner` (`:50`) | Direct Preference Optimization. Logistic regression on objective-score deltas to learn per-objective weights from preference feedback |
| `ActiveLearningSampler.swift` | `enum ActiveLearningSampler` (`:34`) | Ranks schedule pairs by information value (entropy × magnitude); surfaces pairs maximizing DPO entropy reduction |
| `CalendarEmbedding.swift` | `class CalendarEmbedder` (`:55`) | 16-dim fixed-length schedule embeddings via transformer-style pooling. Gradient-free contrastive updates |
| `ChanceConstrainedBuffers.swift` | `struct DurationDistribution` (`:25`) | Lognormal duration distribution; CVaR-aware buffers via Welford streaming accumulator. **Privacy-preserving — no raw samples retained** |

`Application/Learning/` — history-based learners that round-trip through `CloudSyncService`:

| File | Main Type | Role |
|---|---|---|
| `PreferenceLearner.swift` | `class PreferenceLearner` (`:10`) | Meta-GA over objective weight vectors — evolves weights that best predict observed accept/reject/edit. Pushes/restores via CloudKit on changes |
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
| `ScheduleTypes.swift` | `enum Horizon` (`:12`) + others | Shared types: `Horizon`, `Speed`, `Stability`, `WeightKey` enums, `HourRange`, `ScheduleSnapshot`, `ActionableResolution`, `OptimizationResult`, `AppliedSnapshot`. (`Period` moved to `BuboDomain` on 2026-05-12.) |
| `OptimizerModels.swift` | `struct ScheduleGene` (`:17`) | GA gene: eventId, title, startTime, duration, placement metadata. Also holds `OptimizerContext`, `OptimizerPreferences`, `ScheduleScenario`. (`OptimizableEvent` and `PomodoroConfig` moved to `BuboDomain` on 2026-05-12 — see `domain-boundaries.md`.) |
| `TaskSignature.swift` | `struct TaskSignature` (`:28`) | Coarse identity of the optimization workload. Hashes event IDs, 5-min duration buckets, quantized preference weights. **Keys both** the per-workload learner bundle LRU **and** the surrogate/cache state |
| `EventConversion.swift` | `extension CalendarEvent` (`:5`) | `CalendarEvent` → `OptimizableEvent` conversion. Infers focus status, energy cost, Pomodoro config from event metadata |
