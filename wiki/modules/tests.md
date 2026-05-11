# Module: Tests

> **Kind:** module
> **Sources:** Tests/OptimizerTests/, Package.swift
> **Last ingest:** 2026-05-11
> **Related:** [`optimizer.md`](optimizer.md), [`services.md`](services.md), [`viewmodels.md`](viewmodels.md)

## Caveat on the name

The single test target is called `OptimizerTests` for historical reasons. In practice it covers much more than the optimizer — services, persistence, cloud sync, view-model logic, EventKit (mocked), and full-pipeline integration tests all live in the same directory.

Total: **67 files** as of last ingest. Re-count: `ls Tests/OptimizerTests/*.swift | wc -l`.

## What is covered (grouped)

### GA core and operators (14)
`GATests`, `IslandModelGATests`, `ContextualCrossoverTests`, `GraphSubtreeCrossoverTests`, `SymmetryBreakerTests`, `TabuMemoryTests`, `LNSOperatorTests`, `AdaptiveReferencePointsTests`, `AdaptiveWorkloadWeightsTests`, `GAConfigurationPresetTests`, `CPSATSeederTests`, `AnchorSeederTests`, `FocusBurstTests`, `TemporalWarmStartTests`

### Fitness, surrogate, refinement (8)
`HypervolumeTests`, `ComponentFitnessCacheTests`, `ComponentFitnessCacheIntegrationTests`, `MultiFidelityEvaluatorTests`, `RBFSurrogateTests`, `LexicographicFitnessTests`, `ScheduleFeatureVectorTests`, `ScheduleGradientRefinerTests`

### Objectives (1)
`PrecedenceObjectiveTests` — only one per-objective test currently. The remaining 15 objectives are covered indirectly through pipeline tests.

### Constraints and graph caches (9)
`GraphPerformanceTests`, `GraphQueryCacheTests`, `IntentGraphTests`, `IntentGraphSalsaCacheTests`, `ScheduleConflictGraphTests`, `ScheduleConflictGraphSalsaCacheTests`, `ReachabilityBitsetTests`, `QueryDBTests`, `ShardedLRUCacheTests`

### Intents and assistants (4)
`IntentTests`, `PomodoroConfigResolverTests`, `SuggestionEngineTests`, `QuickActionRankerTests`

### Quality-diversity (1)
`QualityDiversityArchiveTests`

### Pomodoro (4)
`PomodoroIntegrationTests`, `PomodoroPhaseTests`, `PomodoroPhaseAlertsTests`, `PomodoroHistoryServiceTests`

### Backlog (5)
`BacklogTests`, `BacklogImprovementsTests`, `BacklogLayoutStateTests`, `BacklogTaskCohesionTests`, `BacklogTaskStoreTests`

### Apple Calendar / Reminders / scheduler (5)
`AppleRemindersServiceTests`, `EventKitSyncCoordinatorTests`, `NotificationSchedulerTests`, `ReminderServiceTests`, `RemindersSyncServiceTests`

### Cloud sync (3)
`CloudServicesCoordinatorTests`, `CloudSyncMergeTests`, `CloudSyncStatusSectionViewModelTests`

### Persistence reconciliation (1)
`UpsertReconcilerTests`

### App composition / pipelines (3)
`AppContainerIntegrationTests`, `FullPipelineIntegrationTests`, `DispatchConfigTests`

### Workload identity (1)
`TaskSignatureTests`

### Training (1)
`TrainingPipelineTests`

### Timeline (1)
`TimelineSlotRankerTests`

### "Wave" regression suites (4)
`Wave2Tests`, `Wave3Tests`, `Wave4Tests`, `Wave5Tests` — batch regression checks tied to release waves.

### Fixtures and helpers (2 — not test files themselves)
`OptimizerTestFixtures.swift`, `TestHelpers+ScheduleGene.swift`

## What is NOT covered

- SwiftUI view rendering / snapshot tests
- EventKit end-to-end with the real `EKEventStore` (fakes only — see `Services/Apple/FakeCalendarEventSource.swift`, `Services/Apple/FakeRemindersEventSource.swift`)
- CloudKit live sync (only merge / coordinator / monitor logic)
- `AgentService` / Claude API and the `proxy/` server
- Global hotkey & AppKit windowing flows (`AppDelegate`)

## How to run

`swift test` from the repo root. SPM manifest: `Package.swift`. The test target depends on the `Bubo` target.

## Fixtures and fakes

- `Tests/OptimizerTests/OptimizerTestFixtures.swift` — shared GA inputs
- `Tests/OptimizerTests/TestHelpers+ScheduleGene.swift` — gene-construction helpers
- `Bubo/Services/Apple/FakeCalendarEventSource.swift`, `FakeRemindersEventSource.swift` — EventKit fakes with invocation recording
- `Bubo/Services/Persistence/InMemoryStores.swift` — fakes for every store protocol
- `Bubo/Services/FakeCloudServices.swift` — fakes for the cloud-sync surfaces
