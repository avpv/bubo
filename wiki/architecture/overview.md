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

`AppContainer.make()` (see `Bubo/AppContainer.swift`) builds the entire service graph **once** at launch:

1. Load `ReminderSettings` from `UserDefaults` + iCloud KVS.
2. Build three SwiftData `ModelContainer`s: `EventCache` (local-only), `UserEvents` (CloudKit-optional), `Backlog` (CloudKit-optional).
3. Construct cross-cutting infrastructure: `CloudServicesCoordinator`, `NetworkMonitor`, `AgentService`.
4. Construct domain services in dependency order: `ReminderService`, `BacklogService`, `OptimizerService`, `RemindersSyncService`.

The container is injected into `BuboApp` `@State` and propagated via SwiftUI `.environment(...)`.

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
