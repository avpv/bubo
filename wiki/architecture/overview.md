# Architecture overview

> **Kind:** architecture
> **Sources:** Bubo/App.swift, Bubo/AppContainer.swift, Bubo/AppDelegate.swift
> **Last ingest:** 2026-05-11
> **Related:** [`persistence.md`](persistence.md), [`event-pipeline.md`](event-pipeline.md), [`../modules/app.md`](../modules/app.md), [`../modules/services.md`](../modules/services.md)

## Shape

Bubo is a single-process macOS app. Entry point is `BuboApp` (`@main`) in `Bubo/App.swift`. The composition root is `AppContainer` (`Bubo/AppContainer.swift`). Long-lived "windowing" responsibilities (full-screen alerts, pinned timer windows, global hotkeys, post-join ribbon) live in `AppDelegate` (`Bubo/AppDelegate.swift`).

There is no module boundary enforced by SPM beyond the single `Bubo` target; the directory layout under `Bubo/` is the de-facto module boundary.

## Layers (top to bottom)

| Layer | Code | Role |
|---|---|---|
| **UI** | `Views/`, `ViewModels/`, `Skins/` | SwiftUI views, settings VM, theming |
| **Services** | `Services/` | Stateful, `@Observable`, `@MainActor`. The "facade" surface views talk to |
| **Optimizer** | `Optimizer/` | Pure-ish GA + constraints + fitness; called from `OptimizerService` |
| **Persistence** | `Services/Persistence/`, `Models/Persistence/` | SwiftData stores; CloudKit-backed `ModelContainer`s |
| **Platform** | EventKit, AppKit, UserNotifications, CloudKit | Native macOS frameworks |

## Composition root

`AppContainer` (`Bubo/AppContainer.swift`, 220 lines) is a `@MainActor struct` that builds the entire service graph **once** at launch. Two entry points:

- **`make()`** (`AppContainer.swift:55`): production path. Reads `cloudSyncPreferenceKey = "BuboCloudSyncEnabled"` from `UserDefaults`. Opens three resilient SwiftData containers backed by `.store` files in Application Support. Constructs `CloudServicesCoordinator` and, if cloud is on, starts it with `iCloud.<bundleId>`. Delegates to `build(...)`.
- **`build(...)`** (`AppContainer.swift:107`): pure wiring step. Given all leaf dependencies, constructs `NetworkMonitor` (default), `AgentService` (default), then in order: `ReminderService` (consumes EventCache + UserEvents containers), `BacklogService` (consumes Backlog container), `OptimizerService` (then has `backlogService` and `energyCheckInService` attached), `RemindersSyncService`. Integration tests call this directly with in-memory containers.

Output properties (`AppContainer.swift:48–56`): `settings`, `networkMonitor`, `agentService`, `cloudServices`, `reminderService`, `backlogService`, `optimizerService`, `remindersSyncService`.

The container is injected into `BuboApp` `@State` and propagated via SwiftUI `.environment(...)`. Live toggling of cloud sync requires an app restart — `ModelContainer` is built once per process.

### Three SwiftData containers

| Container | Schema | CloudKit | Store file |
|---|---|---|---|
| `EventCache` | `PersistedCachedEvent` | always `.none` | `Application Support/EventCache.store` |
| `UserEvents` | `PersistedLocalEvent`, `PersistedExcludedOccurrence`, `PersistedReminderOverride`, `PersistedEventAttributeOverride` | `.automatic` if cloud pref on, else `.none` | `Application Support/UserEvents.store` |
| `Backlog` | `PersistedBacklogTask` | `.automatic` if cloud pref on, else `.none` | `Application Support/Backlog.store` |

`resilientContainer(...)` (`AppContainer.swift:184`) is the recovery wrapper: tries CloudKit-enabled build, falls back to local-only on mirror failure, then to a fresh empty store if the file itself is corrupt.

See [`../modules/app.md`](../modules/app.md) for file-level detail.

## Three patterns that hold the app together

### 1. Observable services

All long-lived services are marked `@MainActor @Observable` (Swift 5.9 observation macro). Views read service properties directly — no Combine `@Published` ceremony. Example: `ReminderService.upcomingEvents` is read directly by `MenuBarView`.

### 2. Notification bus

Cross-cutting events flow through `NotificationCenter`. Topics include `calendarDataChanged`, `.taskAdded`, `.taskUpdated`, `.taskRemoved`, `.taskCompleted`, `.snoozeReminder`, `.didFinishImport`. `AppDelegate` is the primary consumer for alert/window concerns; services consume for cache invalidation. See [`../concepts/notifications-bus.md`](../concepts/notifications-bus.md).

### 3. Protocol-based persistence

Stores (`LocalEventStore`, `BacklogTaskStore`, `ExcludedOccurrenceStore`, `ReminderOverrideStore`, `EventAttributeOverrideStore`) implement protocols defined in `Services/Persistence/Stores.swift`. EventKit access goes through `CalendarEventSource` / `RemindersEventSource` protocols with `Fake*` implementations for tests.

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

- `Models/Domain/` — `CalendarEvent`, `BacklogTask`, `ReminderSettings`, `RecurrenceRule`, `PomodoroDefaults`, etc.
- `Models/Persistence/` — `@Model` SwiftData mirrors of domain types
- `Services/Apple/` — EventKit wrappers + protocol-based event sources
- `Services/Persistence/` — SwiftData stores + `UpsertReconciler` + `InMemoryStores` (fakes)
- `Services/Reminders/` — EventKit sync coordinator + per-event alert scheduler (not the Apple-Reminders bridge — that's flat in `Services/`)
- `Optimizer/GACore/` — generic GA operators
- `Optimizer/Constraints/` — schedule conflict graph, reachability
- `Optimizer/Fitness/Objectives/` — multi-criteria objectives
- `Optimizer/Intents/` — user intent DSL, compiler, NL bridge
- `Optimizer/Learning/` — preference learners, DPO weight tuning
- `Views/` — SwiftUI screens and components
- `Views/Components/` — reusable view widgets
- `Views/Settings/` — settings window tabs
- `Skins/` — theme schema + built-in JSON themes
- `Tests/OptimizerTests/` — optimizer unit tests
