# Module: Tests

> **Kind:** module
> **Sources:** Tests/, Package.swift
> **Last ingest:** 2026-07-18 (PR #599 added `Tests/Domain/RecurrenceExpanderTests.swift` and `Tests/Optimizer/GeneticAlgorithm/CPSATSolverCorrectnessTests.swift` — 67 → 69 test files; layout `Domain/`+`Optimizer/`+`App/`+`Integration/`+`Support/` and SPM target dependencies otherwise unchanged)
> **Related:** [`optimizer.md`](optimizer.md), [`services.md`](services.md), [`viewmodels.md`](viewmodels.md), [`../architecture/layered-structure.md`](../architecture/layered-structure.md)

## Target

The single test target is `BuboTests`. It covers the optimizer, services, persistence, cloud sync, view-model logic, EventKit (mocked), and full-pipeline integration. (The target was renamed from `OptimizerTests` once it became obvious the scope had outgrown the original name.) As of 2026-05-12 it declares three target dependencies — `Bubo`, `BuboDomain`, `BuboOptimizer` — and every test file does `@testable import Bubo` + `@testable import BuboDomain` + `@testable import BuboOptimizer` so internal symbols of all three are reachable.

Total: **69 files**. As of 2026-05-13 the subdirectory layout mirrors the three SwiftPM targets — `Domain/`, `Optimizer/`, `App/` — plus `Integration/` and `Support/` as peers. Re-count: `find Tests -name '*.swift' | wc -l`. SPM's test target walks the directory recursively (`Package.swift`, `path: "Tests"`).

## Layout

```
Tests/
├── Domain/                         # → Sources/Domain/ (4 files)
│                                   # Backlog, BacklogImprovements, RecurrenceExpander, TimelineSlotRanker
├── Optimizer/                      # → Sources/Optimizer/ (36 files)
│   ├── Anchors/                    # AnchorSeederTests
│   ├── Constraints/                # Conflict graph, Salsa caches, QueryDB, ReachabilityBitset, GraphPerformance, GraphQueryCache
│   ├── Fitness/                    # AdaptiveReferencePoints, AdaptiveWorkloadWeights, Hypervolume, Lexicographic, LNSOperator,
│   │                               # MultiFidelityEvaluator, PrecedenceObjective, RBFSurrogate, ScheduleFeatureVector, ScheduleGradientRefiner
│   ├── GeneticAlgorithm/           # GA, IslandModelGA, QualityDiversityArchive, Crossover (Contextual + GraphSubtree), SymmetryBreaker,
│   │                               # TabuMemory, ShardedLRUCache, ComponentFitnessCache {+Integration}, DispatchConfig, CPSATSeeder,
│   │                               # CPSATSolverCorrectness, FocusBurst, GAConfigurationPreset (15 files; kept flat — concerns cross-cut Core/Operators/Repair/Adaptive/IslandModel/Engine)
│   ├── Models/                     # TaskSignature
│   ├── Reoptimizer/                # TemporalWarmStart
│   └── Training/                   # TrainingPipeline
├── App/                            # → Bubo/ executable target (22 files)
│   ├── Application/                # ReminderService, RemindersSync, Pomodoro {Phase, PhaseAlerts, History, Integration}
│   │   └── Intents/                # Intent, IntentGraph, BacklogTaskCohesion, PomodoroConfigResolver, QuickActionRanker, SuggestionEngine
│   ├── Infrastructure/
│   │   ├── Apple/                  # AppleRemindersService, EventKitSyncCoordinator
│   │   ├── Cloud/                  # CloudServicesCoordinator, CloudSyncMerge
│   │   ├── Notifications/          # NotificationScheduler
│   │   └── Persistence/            # BacklogTaskStore, UpsertReconciler
│   └── Presentation/               # Views/Components/Common/BacklogLayoutStateTests,
│                                   # Views/Settings/CloudSyncStatusSectionViewModelTests
├── Integration/                    # AppContainer, FullPipeline, Wave2-5 (6 files)
└── Support/                        # OptimizerTestFixtures.swift, TestHelpers+ScheduleGene.swift (not tests themselves)
```

## What is covered (grouped)

### GA core and operators (15, now under `Optimizer/GeneticAlgorithm/` + `Optimizer/Anchors/` + `Optimizer/Reoptimizer/`)
`GATests`, `IslandModelGATests`, `ContextualCrossoverTests`, `GraphSubtreeCrossoverTests`, `SymmetryBreakerTests`, `TabuMemoryTests`, `LNSOperatorTests` (under `Optimizer/Fitness/`), `AdaptiveReferencePointsTests` (`Optimizer/Fitness/`), `AdaptiveWorkloadWeightsTests` (`Optimizer/Fitness/`), `GAConfigurationPresetTests`, `CPSATSeederTests`, `CPSATSolverCorrectnessTests` (direct `CPSATRepairer.solve` pins — bidirectional forward-check precedence, value-scoped no-goods), `AnchorSeederTests` (`Optimizer/Anchors/`), `FocusBurstTests`, `TemporalWarmStartTests` (`Optimizer/Reoptimizer/`)

### Fitness, surrogate, refinement (8, now under `Optimizer/Fitness/`)
`HypervolumeTests`, `ComponentFitnessCacheTests`, `ComponentFitnessCacheIntegrationTests` (both under `Optimizer/GeneticAlgorithm/`), `MultiFidelityEvaluatorTests`, `RBFSurrogateTests`, `LexicographicFitnessTests`, `ScheduleFeatureVectorTests`, `ScheduleGradientRefinerTests`

### Objectives (1, under `Optimizer/Fitness/`)
`PrecedenceObjectiveTests` — only one per-objective test currently. The remaining 15 objectives are covered indirectly through pipeline tests.

### Constraints and graph caches (9, under `Optimizer/Constraints/`)
`GraphPerformanceTests`, `GraphQueryCacheTests`, `IntentGraphTests` (under `App/Application/Intents/`), `IntentGraphSalsaCacheTests`, `ScheduleConflictGraphTests`, `ScheduleConflictGraphSalsaCacheTests`, `ReachabilityBitsetTests`, `QueryDBTests`, `ShardedLRUCacheTests` (under `Optimizer/GeneticAlgorithm/`)

### Intents and assistants (4, under `App/Application/Intents/`)
`IntentTests`, `PomodoroConfigResolverTests`, `SuggestionEngineTests`, `QuickActionRankerTests`

### Quality-diversity (1, under `Optimizer/GeneticAlgorithm/`)
`QualityDiversityArchiveTests`

### Pomodoro (4, under `App/Application/` + `App/Application/Intents/`)
`PomodoroIntegrationTests`, `PomodoroPhaseTests`, `PomodoroPhaseAlertsTests`, `PomodoroHistoryServiceTests` (all under `App/Application/`)

### Backlog (5, split across `Domain/` + `App/Application/Intents/` + `App/Presentation/` + `App/Infrastructure/Persistence/`)
`BacklogTests` (`Domain/`), `BacklogImprovementsTests` (`Domain/`), `BacklogLayoutStateTests` (`App/Presentation/Views/Components/Common/`), `BacklogTaskCohesionTests` (`App/Application/Intents/`), `BacklogTaskStoreTests` (`App/Infrastructure/Persistence/`)

### Apple Calendar / Reminders / scheduler (5, under `App/Infrastructure/` + `App/Application/`)
`AppleRemindersServiceTests` (`App/Infrastructure/Apple/`), `EventKitSyncCoordinatorTests` (`App/Infrastructure/Apple/`), `NotificationSchedulerTests` (`App/Infrastructure/Notifications/`), `ReminderServiceTests` (`App/Application/`), `RemindersSyncServiceTests` (`App/Application/`)

### Cloud sync (3, under `App/Infrastructure/Cloud/` + `App/Presentation/`)
`CloudServicesCoordinatorTests`, `CloudSyncMergeTests`, `CloudSyncStatusSectionViewModelTests` (`App/Presentation/Views/Settings/`)

### Persistence reconciliation (1, under `App/Infrastructure/Persistence/`)
`UpsertReconcilerTests`

### App composition / pipelines (3, under `Integration/` + `Optimizer/GeneticAlgorithm/`)
`AppContainerIntegrationTests`, `FullPipelineIntegrationTests`, `DispatchConfigTests` (`Optimizer/GeneticAlgorithm/`)

### Workload identity (1, under `Optimizer/Models/`)
`TaskSignatureTests`

### Training (1, under `Optimizer/Training/`)
`TrainingPipelineTests`

### Timeline (1, under `Domain/`)
`TimelineSlotRankerTests`

### Recurrence (1, under `Domain/`)
`RecurrenceExpanderTests` — monthly seed-month occurrence, pomodoro `_occ{N}` round ids, same-day EXDATE matching, `FREQ=MONTHLY;BYDAY=FR` → weekly mapping (2026-07-16 core audit pins)

### "Wave" regression suites (4, under `Integration/`)
`Wave2Tests`, `Wave3Tests`, `Wave4Tests`, `Wave5Tests` — batch regression checks tied to release waves.

### Fixtures and helpers (2, under `Support/`)
`Support/OptimizerTestFixtures.swift`, `Support/TestHelpers+ScheduleGene.swift`

## What is NOT covered

- SwiftUI view rendering / snapshot tests
- EventKit end-to-end with the real `EKEventStore` (fakes only — see `Bubo/Infrastructure/Apple/Fakes/FakeCalendarEventSource.swift`, `Bubo/Infrastructure/Apple/Fakes/FakeRemindersEventSource.swift`)
- CloudKit live sync (only merge / coordinator / monitor logic)
- `AgentService` / DeepSeek API and the `proxy/` server
- Global hotkey & AppKit windowing flows (`AppDelegate`)

## How to run

`swift test` from the repo root. SPM manifest: `Package.swift`. The test target depends on `Bubo`, `BuboDomain`, and `BuboOptimizer`.

## Fixtures and fakes

- `Tests/Support/OptimizerTestFixtures.swift` — shared GA inputs
- `Tests/Support/TestHelpers+ScheduleGene.swift` — gene-construction helpers
- `Bubo/Infrastructure/Apple/Fakes/FakeCalendarEventSource.swift`, `FakeRemindersEventSource.swift` — EventKit fakes with invocation recording
- `Bubo/Infrastructure/Persistence/InMemoryStores.swift` — fakes for every store protocol
- `Bubo/Infrastructure/Cloud/Fakes/FakeCloudServices.swift` — fakes for the cloud-sync surfaces
