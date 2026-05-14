# Architecture overview

> **Kind:** architecture
> **Sources:** Package.swift, Bubo/Composition/App/App.swift, Bubo/Composition/App/AppContainer.swift, Bubo/Composition/AppDelegate/AppDelegate.swift
> **Last ingest:** 2026-05-14 (rev: line refs into `AppContainer.swift` bumped by 1–2 (`:54` make, `:107` build, `:190` resilientContainer); `Infrastructure/Bundle/` one-liner corrected — Keychain/NetworkMonitor/EventCache live in their own peer subdirs, not under `Bundle/`)
> **Related:** [`layered-structure.md`](layered-structure.md), [`domain-boundaries.md`](domain-boundaries.md), [`persistence.md`](persistence.md), [`event-pipeline.md`](event-pipeline.md), [`../modules/app.md`](../modules/app.md), [`../modules/services.md`](../modules/services.md)

## Shape

Bubo is a single-process macOS app. Entry point is `BuboApp` (`@main`) in `Bubo/Composition/App/App.swift`. The composition root is `AppContainer` (`Bubo/Composition/App/AppContainer.swift`). Long-lived "windowing" responsibilities (full-screen alerts, pinned timer windows, global hotkeys, post-join ribbon) live in `AppDelegate` (`Bubo/Composition/AppDelegate/AppDelegate.swift`).

Since 2026-05-12 the codebase is split into **three SwiftPM targets** (`Package.swift`): `BuboDomain` (pure value types, no deps), `BuboOptimizer` (the multi-objective GA, depends on `BuboDomain`), and `Bubo` (the macOS executable, depends on both). The inner Composition/Application/Infrastructure/Presentation distinction still lives as folders inside the `Bubo` target — folder rules are convention-enforced there, target rules are compiler-enforced between modules. See [`layered-structure.md`](layered-structure.md) for the full target graph.

## Layers (top to bottom)

| Layer | Code | Target | Role |
|---|---|---|---|
| **UI** | `Bubo/Presentation/Views/`, `Bubo/Presentation/Views/Settings/`, `Bubo/Presentation/Views/Skins/` (incl. `Skins/Wallpaper/`) | `Bubo` | SwiftUI views, settings VM, theming, wallpaper catalog |
| **Services** | `Bubo/Application/` (+ `Bubo/Infrastructure/Apple/`, `Bubo/Infrastructure/Cloud/`, `Bubo/Infrastructure/Notifications/`) | `Bubo` | Stateful, `@Observable`, `@MainActor`. The "facade" surface views talk to |
| **Optimizer** | `Sources/Optimizer/` | `BuboOptimizer` | Pure-ish GA + constraints + fitness; called from `OptimizerService`. Standalone SwiftPM module |
| **Domain** | `Sources/Domain/` | `BuboDomain` | Value types + stateless namespaces. Foundation/Observation only. Standalone SwiftPM module |
| **Persistence** | `Bubo/Infrastructure/Persistence/` | `Bubo` | SwiftData stores; CloudKit-backed `ModelContainer`s |
| **Platform** | EventKit, AppKit, UserNotifications, CloudKit | (system) | Native macOS frameworks |

## Composition root

`AppContainer` (`Bubo/Composition/App/AppContainer.swift`, 217 lines) is a `@MainActor struct` that builds the entire service graph **once** at launch. Two entry points:

- **`make()`** (`AppContainer.swift:54`): production path. Reads `cloudSyncPreferenceKey = "BuboCloudSyncEnabled"` (`:27`) from `UserDefaults`. Opens three resilient SwiftData containers backed by `.store` files in Application Support. Constructs `CloudServicesCoordinator` and, if cloud is on, starts it with `iCloud.<bundleId>`. Delegates to `build(...)`.
- **`build(...)`** (`AppContainer.swift:107`): pure wiring step. Given all leaf dependencies, constructs `NetworkMonitor` (default), `AgentService` (default), then in order: `ReminderService` (consumes EventCache + UserEvents containers), `BacklogService` (consumes Backlog container), `OptimizerService` (then has `backlogService` and `energyCheckInService` attached), `RemindersSyncService`. Integration tests call this directly with in-memory containers.

Output properties (`AppContainer.swift:38–46`): `settings`, `networkMonitor`, `agentService`, `cloudServices`, `reminderService`, `backlogService`, `optimizerService`, `remindersSyncService`.

The container is injected into `BuboApp` `@State` and propagated via SwiftUI `.environment(...)`. Live toggling of cloud sync requires an app restart — `ModelContainer` is built once per process.

### Three SwiftData containers

| Container | Schema | CloudKit | Store file |
|---|---|---|---|
| `EventCache` | `PersistedCachedEvent` | always `.none` | `Application Support/EventCache.store` |
| `UserEvents` | `PersistedLocalEvent`, `PersistedExcludedOccurrence`, `PersistedReminderOverride`, `PersistedEventAttributeOverride` | `.automatic` if cloud pref on, else `.none` | `Application Support/UserEvents.store` |
| `Backlog` | `PersistedBacklogTask` | `.automatic` if cloud pref on, else `.none` | `Application Support/Backlog.store` |

`resilientContainer(...)` (`AppContainer.swift:190`) is the recovery wrapper: tries CloudKit-enabled build, falls back to local-only on mirror failure, then to a fresh empty store if the file itself is corrupt.

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
- `Infrastructure/Apple/` — EventKit wrappers + protocol-based event sources (`AppleCalendarService`, `AppleRemindersService`, `EventKitSyncCoordinator`)
- `Infrastructure/Cloud/` — CloudKit account/sync monitor + `CloudServicesCoordinator`
- `Infrastructure/Notifications/` — `NotificationScheduler` (per-event alerts, UserNotifications delivery, full-screen-alert bridge)
- `Infrastructure/Security/` — `Keychain`
- `Infrastructure/Network/` — `NetworkMonitor`
- `Infrastructure/Cache/` — `EventCache` settings
- `Infrastructure/Bundle/` — `ResourceBundle` (safeModule fallback for the SPM resource bundle)
- `Optimizer/GeneticAlgorithm/` — generic GA, subdivided into `Core/`, `Operators/`, `Repair/`, `Adaptive/`, `IslandModel/`, `Engine/`
- `Optimizer/Constraints/` — schedule conflict graph, reachability
- `Optimizer/Fitness/Objectives/` — multi-criteria objectives
- `Application/Intents/` — user intent DSL, compiler, NL bridge (moved out of `Optimizer/` because compilers reference `*Service` types). Subdivided into `Compiler/`, `Graph/`, `Engines/`, `Rules/`, `Bridges/` on 2026-05-12.
- `Optimizer/Learning/` — pure adaptive pieces (active sampler, embedding, chance buffers, DPO weights). History-based learners (`IntentLearner`, `PreferenceLearner`) live in `Application/Learning/` because they sync via `CloudSyncService`.
- `Presentation/Views/` — SwiftUI screens and components
- `Presentation/Views/Components/` — reusable view widgets
- `Presentation/Views/Settings/` — settings window tabs
- `Presentation/Views/Skins/` — theme schema + built-in JSON themes
- `Tests/` — optimizer unit tests (SwiftPM target `BuboTests`)
