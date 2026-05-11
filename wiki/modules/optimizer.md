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

- `BuboOptimizer` — the facade in `Optimizer/GACore/BuboOptimizer.swift`. Tracks `scenarios[]`, learner bundles (LRU keyed by `TaskSignature`), and re-optimization requests.
- `IntentLearner` — observes user accept/reject and updates intent weights.
- `lockedEventIds`, `excludedEventIds` — user-driven constraints surfaced from UI.
- `shadowProposal` — current ghost preview the user can accept with one click.

## GACore key types

| File | Type | Role |
|---|---|---|
| `BuboOptimizer.swift` | `BuboOptimizer` | Facade; learner-bundle LRU; re-opt queue |
| `GeneticAlgorithm.swift` | `GeneticAlgorithm` | Main evolutionary loop |
| `IslandModelGA.swift` | island variant | Multiple subpopulations for diversity |
| `Chromosome.swift` | `Chromosome` | Encoding: task → slot assignment |
| `PomodoroSequenceChromosome.swift` | | Pomodoro-aware sequence encoding |
| `Population.swift` | `Population` | Container + diversity metrics |
| `Selection.swift` | `TournamentSelection`, `RouletteWheelSelection` | Selection ops |
| `Crossover.swift`, `ContextualCrossover.swift` | | Crossover ops |
| `Mutation.swift`, `MutationBandit.swift` | | Adaptive mutation per workload (multi-armed bandit) |
| `LNSStrategyBandit.swift` | | Large-neighbourhood-search strategy bandit |
| `PathRelinking.swift` | | Local search between elite solutions |
| `SymmetryBreaker.swift` | | Drops redundant equivalent solutions |
| `TabuMemory.swift` | | Tabu search short-term memory |
| `CPSATRepair.swift` | | Hard-constraint repair (CPSAT-style) |
| `SlotDomain.swift`, `SlotRegistry.swift` | | Free-slot enumeration |
| `GARandom.swift` | | Reproducible RNG |
| `EvolutionHooks.swift` | | Observer hooks for UI/learning |
| `FitnessPlateauDetector.swift` | | Early stopping |
| `QualityDiversityArchive.swift` | | QD archive |
| `GADebugLog.swift` | | Diagnostics |
| `GNNWarmStart.swift` | | Graph-NN warm-start |

## Constraints

`Constraints/` enforces hard rules — conflicts, precedence, reachability. Notable types: `Constraint` protocol, `ConstraintEngine`, `ScheduleConflictGraph` (+ a SALSA cache variant), `IntentGraphSalsaCache`, `GraphQueryCache`, `ReachabilityBitset`, `QueryDB`.

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

`Learning/` contains preference learning (`PreferenceLearner.swift`, `DPOWeightLearner.swift`), an active-learning sampler (`ActiveLearningSampler.swift`), a learned calendar embedding (`CalendarEmbedding.swift`), and chance-constrained buffers (`ChanceConstrainedBuffers.swift`). `IntentLearner.swift` also lives here (`Bubo/Optimizer/Learning/IntentLearner.swift` — not in `Intents/`).

## Re-optimizer

`Reoptimizer/` warm-starts the GA from the prior solution when the calendar changes incrementally instead of running from scratch. `ProactiveReactivePolicy.swift` decides whether to auto-reopt or wait for a user trigger. `TemporalWarmStart.swift` provides temporal continuity seeding.

## Scenarios & Training

`Scenarios/ScenarioGenerator.swift` generates N candidate scenarios after a GA run. `MAPElitesArchive.swift` is the quality-diversity store. `Training/` is offline preference learning: `TrainingCoordinator`, `SyntheticPreferencePairGenerator`, `TrainingReplayBuffer`, `TrainingMetrics`, `TrainingPersistence`. The `BuboOptimizer+Training.swift` and `BuboOptimizer+Learning.swift` files extend the facade.

## Concurrency

GA runs are queued on a background dispatch queue inside `BuboOptimizer`. Results are published back to `@MainActor` via `OptimizerService`. Cancellation is supported when the input changes mid-run.
