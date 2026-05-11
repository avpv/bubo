# Module: Tests

> **Kind:** module
> **Sources:** Tests/OptimizerTests/, Package.swift
> **Last ingest:** 2026-05-11
> **Related:** [`optimizer.md`](optimizer.md), [`services.md`](services.md), [`viewmodels.md`](viewmodels.md)

## Caveat on the name

The single test target is called `OptimizerTests` for historical reasons. In practice it covers much more than the optimizer — services, persistence, cloud sync, view-model logic, and integration paths all live in the same directory.

## What is covered

Sampled file inventory of `Tests/OptimizerTests/`:

- **GA & operators:** `GATests`, `ContextualCrossoverTests`, `GraphSubtreeCrossoverTests`, `AdaptiveReferencePointsTests`, `AdaptiveWorkloadWeightsTests`, `GAConfigurationPresetTests`, `CPSATSeederTests`, `AnchorSeederTests`, `FocusBurstTests`
- **Fitness & graphs:** `HypervolumeTests`, `ComponentFitnessCacheTests`, `ComponentFitnessCacheIntegrationTests`, `GraphPerformanceTests`, `GraphQueryCacheTests`, `IntentGraphSalsaCacheTests`, `IntentGraphTests`
- **Intents:** `IntentTests`, `IntentGraphTests`, `IntentGraphSalsaCacheTests`
- **Backlog:** `BacklogTests`, `BacklogImprovementsTests`, `BacklogTaskCohesionTests`, `BacklogLayoutStateTests`, `BacklogTaskStoreTests`
- **Apple integration (mocked):** `AppleRemindersServiceTests`, `EventKitSyncCoordinatorTests`
- **Cloud sync:** `CloudServicesCoordinatorTests`, `CloudSyncMergeTests`, `CloudSyncStatusSectionViewModelTests`
- **App composition:** `AppContainerIntegrationTests`, `FullPipelineIntegrationTests`, `DispatchConfigTests`

(List is illustrative — `ls Tests/OptimizerTests/` for the full set.)

## What is NOT covered

- SwiftUI view rendering / snapshot tests
- EventKit end-to-end with the real `EKEventStore` (fakes only)
- CloudKit live sync (only the merge/coordinator logic)
- `AgentService` / Claude API and the `proxy/` server
- Global hotkey & AppKit windowing flows (`AppDelegate`)

## How to run

`swift test` from the repo root. SPM manifest: `Package.swift`. Test target depends on the `Bubo` target.

## Fixtures and fakes

- `Services/Apple/CalendarEventSource.swift` and `RemindersEventSource.swift` — protocol + `Fake*` impl
- `Services/Persistence/InMemoryStores.swift` — in-memory implementations of every store protocol
- `Services/FakeCloudServices.swift` — fakes for the cloud-sync surfaces
