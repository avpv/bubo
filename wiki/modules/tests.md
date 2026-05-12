# Module: Tests

> **Kind:** module
> **Sources:** Tests/BuboTests/, Package.swift
> **Last ingest:** 2026-05-12
> **Related:** [`optimizer.md`](optimizer.md), [`services.md`](services.md), [`viewmodels.md`](viewmodels.md)

## Target

The single test target is `BuboTests`. It covers the optimizer, services, persistence, cloud sync, view-model logic, EventKit (mocked), and full-pipeline integration. (The target was renamed from `OptimizerTests` once it became obvious the scope had outgrown the original name.)

Total: **67 files**, now spread across 14 subfolders mirroring the source layout. Re-count: `find Tests/BuboTests -name '*.swift' | wc -l`. SPM's test target walks the directory recursively (`Package.swift:24, path: "Tests/BuboTests"`).

## Layout

```
Tests/BuboTests/
├── Anchors/                    # AnchorSeederTests
├── Application/                # ReminderService, RemindersSync, Pomodoro {Phase, PhaseAlerts, History, Integration}
├── Constraints/                # Conflict graph, Salsa caches, IntentGraphSalsaCache, QueryDB, ReachabilityBitset, GraphPerformance, GraphQueryCache
├── Domain/                     # Backlog, BacklogImprovements, TimelineSlotRanker
├── Fitness/                    # AdaptiveReferencePoints, AdaptiveWorkloadWeights, Hypervolume, Lexicographic, LNSOperator,
│                               # MultiFidelityEvaluator, PrecedenceObjective, RBFSurrogate, ScheduleFeatureVector, ScheduleGradientRefiner
├── GACore/                     # GA, IslandModelGA, QualityDiversityArchive, Crossover (Contextual + GraphSubtree), SymmetryBreaker,
│                               # TabuMemory, ShardedLRUCache, ComponentFitnessCache {+Integration}, DispatchConfig, CPSATSeeder,
│                               # FocusBurst, GAConfigurationPreset
├── Infrastructure/
│   ├── Apple/                  # AppleRemindersServiceTests
│   ├── Cloud/                  # CloudServicesCoordinator, CloudSyncMerge
│   ├── Persistence/            # BacklogTaskStore, UpsertReconciler
│   └── Reminders/              # EventKitSyncCoordinator, NotificationScheduler
├── Integration/                # AppContainer, FullPipeline, Wave2-5
├── Intents/                    # Intent, IntentGraph, BacklogTaskCohesion, PomodoroConfigResolver, QuickActionRanker, SuggestionEngine
├── Models/                     # TaskSignature
├── Presentation/               # Views/Components/Common/BacklogLayoutStateTests,
│                               # Views/Settings/CloudSyncStatusSectionViewModelTests
│                               # (subfolders mirror the source layout, 2026-05-12)
├── Reoptimizer/                # TemporalWarmStart
├── Support/                    # OptimizerTestFixtures.swift, TestHelpers+ScheduleGene.swift (not tests themselves)
└── Training/                   # TrainingPipeline
```

## What is covered (grouped)

### GA core and operators (14, now under `GACore/` + `Anchors/` + `Reoptimizer/`)
`GATests`, `IslandModelGATests`, `ContextualCrossoverTests`, `GraphSubtreeCrossoverTests`, `SymmetryBreakerTests`, `TabuMemoryTests`, `LNSOperatorTests` (under `Fitness/`), `AdaptiveReferencePointsTests` (`Fitness/`), `AdaptiveWorkloadWeightsTests` (`Fitness/`), `GAConfigurationPresetTests`, `CPSATSeederTests`, `AnchorSeederTests` (`Anchors/`), `FocusBurstTests`, `TemporalWarmStartTests` (`Reoptimizer/`)

### Fitness, surrogate, refinement (8, now under `Fitness/`)
`HypervolumeTests`, `ComponentFitnessCacheTests`, `ComponentFitnessCacheIntegrationTests` (both under `GACore/`), `MultiFidelityEvaluatorTests`, `RBFSurrogateTests`, `LexicographicFitnessTests`, `ScheduleFeatureVectorTests`, `ScheduleGradientRefinerTests`

### Objectives (1, under `Fitness/`)
`PrecedenceObjectiveTests` — only one per-objective test currently. The remaining 15 objectives are covered indirectly through pipeline tests.

### Constraints and graph caches (9, under `Constraints/`)
`GraphPerformanceTests`, `GraphQueryCacheTests`, `IntentGraphTests` (under `Intents/`), `IntentGraphSalsaCacheTests`, `ScheduleConflictGraphTests`, `ScheduleConflictGraphSalsaCacheTests`, `ReachabilityBitsetTests`, `QueryDBTests`, `ShardedLRUCacheTests` (under `GACore/`)

### Intents and assistants (4, under `Intents/`)
`IntentTests`, `PomodoroConfigResolverTests`, `SuggestionEngineTests`, `QuickActionRankerTests`

### Quality-diversity (1, under `GACore/`)
`QualityDiversityArchiveTests`

### Pomodoro (4, under `Application/` + `Intents/`)
`PomodoroIntegrationTests`, `PomodoroPhaseTests`, `PomodoroPhaseAlertsTests`, `PomodoroHistoryServiceTests` (all under `Application/`)

### Backlog (5, split across `Domain/` + `Intents/` + `Presentation/` + `Infrastructure/Persistence/`)
`BacklogTests` (`Domain/`), `BacklogImprovementsTests` (`Domain/`), `BacklogLayoutStateTests` (`Presentation/Views/Components/Common/`), `BacklogTaskCohesionTests` (`Intents/`), `BacklogTaskStoreTests` (`Infrastructure/Persistence/`)

### Apple Calendar / Reminders / scheduler (5, under `Infrastructure/` + `Application/`)
`AppleRemindersServiceTests` (`Infrastructure/Apple/`), `EventKitSyncCoordinatorTests` (`Infrastructure/Reminders/`), `NotificationSchedulerTests` (`Infrastructure/Reminders/`), `ReminderServiceTests` (`Application/`), `RemindersSyncServiceTests` (`Application/`)

### Cloud sync (3, under `Infrastructure/Cloud/` + `Presentation/`)
`CloudServicesCoordinatorTests`, `CloudSyncMergeTests`, `CloudSyncStatusSectionViewModelTests` (`Presentation/Views/Settings/`)

### Persistence reconciliation (1, under `Infrastructure/Persistence/`)
`UpsertReconcilerTests`

### App composition / pipelines (3, under `Integration/` + `GACore/`)
`AppContainerIntegrationTests`, `FullPipelineIntegrationTests`, `DispatchConfigTests` (`GACore/`)

### Workload identity (1, under `Models/`)
`TaskSignatureTests`

### Training (1, under `Training/`)
`TrainingPipelineTests`

### Timeline (1, under `Domain/`)
`TimelineSlotRankerTests`

### "Wave" regression suites (4, under `Integration/`)
`Wave2Tests`, `Wave3Tests`, `Wave4Tests`, `Wave5Tests` — batch regression checks tied to release waves.

### Fixtures and helpers (2, under `Support/`)
`Support/OptimizerTestFixtures.swift`, `Support/TestHelpers+ScheduleGene.swift`

## What is NOT covered

- SwiftUI view rendering / snapshot tests
- EventKit end-to-end with the real `EKEventStore` (fakes only — see `Infrastructure/Apple/FakeCalendarEventSource.swift`, `Infrastructure/Apple/FakeRemindersEventSource.swift`)
- CloudKit live sync (only merge / coordinator / monitor logic)
- `AgentService` / DeepSeek API and the `proxy/` server
- Global hotkey & AppKit windowing flows (`AppDelegate`)

## How to run

`swift test` from the repo root. SPM manifest: `Package.swift`. The test target depends on the `Bubo` target.

## Fixtures and fakes

- `Tests/BuboTests/Support/OptimizerTestFixtures.swift` — shared GA inputs
- `Tests/BuboTests/Support/TestHelpers+ScheduleGene.swift` — gene-construction helpers
- `Bubo/Infrastructure/Apple/Fakes/FakeCalendarEventSource.swift`, `FakeRemindersEventSource.swift` — EventKit fakes with invocation recording
- `Bubo/Infrastructure/Persistence/InMemoryStores.swift` — fakes for every store protocol
- `Bubo/Infrastructure/Cloud/Fakes/FakeCloudServices.swift` — fakes for the cloud-sync surfaces
