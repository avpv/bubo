# Architecture overview

> **Kind:** architecture
> **Sources:** Bubo/Composition/App.swift, Bubo/Composition/AppContainer.swift, Bubo/Composition/AppDelegate.swift
> **Last ingest:** 2026-05-12 (rev: Common/ViewModels/Optimizer subfolder rename + BuboTests)
> **Related:** [`persistence.md`](persistence.md), [`event-pipeline.md`](event-pipeline.md), [`../modules/app.md`](../modules/app.md), [`../modules/services.md`](../modules/services.md)

## Shape

Bubo is a single-process macOS app. Entry point is `BuboApp` (`@main`) in `Bubo/Composition/App.swift`. The composition root is `AppContainer` (`Bubo/Composition/AppContainer.swift`). Long-lived "windowing" responsibilities (full-screen alerts, pinned timer windows, global hotkeys, post-join ribbon) live in `AppDelegate` (`Bubo/Composition/AppDelegate.swift`).

There is no module boundary enforced by SPM beyond the single `Bubo` target; the directory layout under `Bubo/` is the de-facto module boundary.

## Layers (top to bottom)

| Layer | Code | Role |
|---|---|---|
| **UI** | `Presentation/Views/`, `Presentation/Views/Settings/`, `Presentation/Skins/` | SwiftUI views, settings VM, theming |
| **Services** | `Application/` (+ `Infrastructure/Apple/`, `Infrastructure/Cloud/`, `Infrastructure/Reminders/`) | Stateful, `@Observable`, `@MainActor`. The "facade" surface views talk to |
| **Optimizer** | `Optimizer/` | Pure-ish GA + constraints + fitness; called from `OptimizerService` |
| **Persistence** | `Infrastructure/Persistence/` | SwiftData stores; CloudKit-backed `ModelContainer`s |
| **Platform** | EventKit, AppKit, UserNotifications, CloudKit | Native macOS frameworks |

## Composition root

`AppContainer` (`Bubo/Composition/AppContainer.swift`, 215 lines) is a `@MainActor struct` that builds the entire service graph **once** at launch. Two entry points:

- **`make()`** (`AppContainer.swift:53`): production path. Reads `cloudSyncPreferenceKey = "BuboCloudSyncEnabled"` (`:26`) from `UserDefaults`. Opens three resilient SwiftData containers backed by `.store` files in Application Support. Constructs `CloudServicesCoordinator` and, if cloud is on, starts it with `iCloud.<bundleId>`. Delegates to `build(...)`.
- **`build(...)`** (`AppContainer.swift:106`): pure wiring step. Given all leaf dependencies, constructs `NetworkMonitor` (default), `AgentService` (default), then in order: `ReminderService` (consumes EventCache + UserEvents containers), `BacklogService` (consumes Backlog container), `OptimizerService` (then has `backlogService` and `energyCheckInService` attached), `RemindersSyncService`. Integration tests call this directly with in-memory containers.

Output properties (`AppContainer.swift:37–44`): `settings`, `networkMonitor`, `agentService`, `cloudServices`, `reminderService`, `backlogService`, `optimizerService`, `remindersSyncService`.

The container is injected into `BuboApp` `@State` and propagated via SwiftUI `.environment(...)`. Live toggling of cloud sync requires an app restart — `ModelContainer` is built once per process.

### Three SwiftData containers

| Container | Schema | CloudKit | Store file |
|---|---|---|---|
| `EventCache` | `PersistedCachedEvent` | always `.none` | `Application Support/EventCache.store` |
| `UserEvents` | `PersistedLocalEvent`, `PersistedExcludedOccurrence`, `PersistedReminderOverride`, `PersistedEventAttributeOverride` | `.automatic` if cloud pref on, else `.none` | `Application Support/UserEvents.store` |
| `Backlog` | `PersistedBacklogTask` | `.automatic` if cloud pref on, else `.none` | `Application Support/Backlog.store` |

`resilientContainer(...)` (`AppContainer.swift:188`) is the recovery wrapper: tries CloudKit-enabled build, falls back to local-only on mirror failure, then to a fresh empty store if the file itself is corrupt.

See [`../modules/app.md`](../modules/app.md) for file-level detail.

## Three patterns that hold the app together

### 1. Observable services

All long-lived services are marked `@MainActor @Observable` (Swift 5.9 observation macro). Views read service properties directly — no Combine `@Published` ceremony. Example: `ReminderService.upcomingEvents` is read directly by `MenuBarView`.

### 2. Notification bus

Cross-cutting events flow through `NotificationCenter`. Topics include `calendarDataChanged`, `.taskAdded`, `.taskUpdated`, `.taskRemoved`, `.taskCompleted`, `.snoozeReminder`, `.didFinishImport`. `AppDelegate` is the primary consumer for alert/window concerns; services consume for cache invalidation. See [`../concepts/notifications-bus.md`](../concepts/notifications-bus.md).

### 3. Protocol-based persistence

Stores (`LocalEventStore`, `BacklogTaskStore`, `ExcludedOccurrenceStore`, `ReminderOverrideStore`, `EventAttributeOverrideStore`) implement protocols defined in `Infrastructure/Persistence/Stores.swift`. EventKit access goes through `CalendarEventSource` / `RemindersEventSource` protocols with `Fake*` implementations for tests.

## Data flow: a single calendar tick

```
EKEventStoreChanged (system notification)
  → AppleCalendarService posts `calendarDataChanged`
    → EventKitSyncCoordinator pulls events, hits ExcludedOccurrenceStore + EventAttributeOverrideStore
      → ReminderService updates upcomingEvents (observable)
        → MenuBarView re-renders timeline
        → NotificationScheduler reschedules per-event timers
        → AppDelegate uses fired timers to present FullScreenAlertView
```

`OptimizerService` reacts to changes in `upcomingEvents` + `BacklogService.tasks` by enqueuing a GA run on a background queue and updating `scenarios[]` when done. See [`../modules/optimizer.md`](../modules/optimizer.md).

## What lives where (one-liner per subdirectory)

- `Domain/` — `CalendarEvent`, `BacklogTask`, `ReminderSettings`, `RecurrenceRule`, `PomodoroDefaults`, etc.
- `Infrastructure/Persistence/` — `@Model` SwiftData mirrors of domain types, stores, `UpsertReconciler`, `InMemoryStores` (fakes)
- `Infrastructure/Apple/` — EventKit wrappers + protocol-based event sources (`AppleCalendarService`, `AppleRemindersService`)
- `Infrastructure/Cloud/` — CloudKit account/sync monitor + `CloudServicesCoordinator`
- `Infrastructure/Reminders/` — `EventKitSyncCoordinator` + `NotificationScheduler` (per-event alerts)
- `Infrastructure/System/` — `Keychain`, `NetworkMonitor`, `EventCache` settings, `ResourceBundle`
- `Optimizer/GeneticAlgorithm/` — generic GA operators
- `Optimizer/Constraints/` — schedule conflict graph, reachability
- `Optimizer/Fitness/Objectives/` — multi-criteria objectives
- `Application/Intents/` — user intent DSL, compiler, NL bridge (moved out of `Optimizer/` because compilers reference `*Service` types)
- `Optimizer/Learning/` — pure adaptive pieces (active sampler, embedding, chance buffers, DPO weights). History-based learners (`IntentLearner`, `PreferenceLearner`) live in `Application/Learning/` because they sync via `CloudSyncService`.
- `Presentation/Views/` — SwiftUI screens and components
- `Presentation/Views/Components/` — reusable view widgets
- `Presentation/Views/Settings/` — settings window tabs
- `Presentation/Skins/` — theme schema + built-in JSON themes
- `Tests/BuboTests/` — optimizer unit tests
