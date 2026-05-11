# Module: Services

> **Kind:** module
> **Sources:** Bubo/Services/
> **Last ingest:** 2026-05-11
> **Related:** [`../architecture/overview.md`](../architecture/overview.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md), [`../concepts/notifications-bus.md`](../concepts/notifications-bus.md), [`optimizer.md`](optimizer.md)

## Layout

```
Services/
├── Apple/         # EventKit + Reminders wrappers, protocol-based sources
├── Persistence/   # SwiftData stores + reconciler
├── Reminders/     # EventKit sync coordinator, per-event alert scheduler
└── <flat>         # Orchestrators, helpers, networking, Apple-Reminders bridge
```

Note: the `Reminders/` directory is named after *macOS notifications/reminders* (alerts and EventKit sync timing), not Apple Reminders. The Apple-Reminders bridge service (`RemindersSyncService.swift`) lives flat in `Services/`.

Services are typically `@MainActor @Observable` singletons constructed once in `AppContainer`.

## Orchestrators (the public surface)

| Service | Owns | Read by |
|---|---|---|
| `ReminderService` | `upcomingEvents`, `localEvents`, `EventKitSyncCoordinator`, `NotificationScheduler` | `MenuBarView`, `OptimizerService`, `AppDelegate` |
| `BacklogService` | `tasks`, `BacklogTaskStore` | `BacklogFullscreenView`, `OptimizerService`, `EditTaskView` |
| `OptimizerService` | `BuboOptimizer`, `IntentLearner`, `scenarios`, `shadowProposal` | `MenuBarView` (ghost previews), `OptimizerTabView`, `CommandPalette` |
| `AgentService` | Anthropic client, rate-limit window | `AITabView`, `CommandPalette` |

## Apple (`Services/Apple/`)

| File | Type | Role |
|---|---|---|
| `AppleCalendarService.swift` | `AppleCalendarService` | EventKit access; listens for `EKEventStoreChanged`; posts `calendarDataChanged` |
| `AppleRemindersService.swift` | `AppleRemindersService` | Reminders read |
| `CalendarEventSource.swift` | `CalendarEventSource` protocol + `Apple*` + `Fake*` | Boundary for tests |
| `RemindersEventSource.swift` | `RemindersEventSource` protocol + impls | Same idea for reminders |

## Persistence (`Services/Persistence/`)

| File | Type | Role |
|---|---|---|
| `LocalEventStore.swift` | `LocalEventStore` | Locally-authored events |
| `BacklogTaskStore.swift` | `BacklogTaskStore` | Backlog tasks |
| `ExcludedOccurrenceStore.swift` | `ExcludedOccurrenceStore` | Per-occurrence tombstones |
| `ReminderOverrideStore.swift` | `ReminderOverrideStore` | Per-event reminder count |
| `EventAttributeOverrideStore.swift` | `EventAttributeOverrideStore` | Per-event color/name overlay |
| `Stores.swift` | protocols | Shared store interfaces |
| `InMemoryStores.swift` | in-memory fakes | Test substitutes for every store protocol |
| `UpsertReconciler.swift` | `UpsertReconciler` | Merges CloudKit imports into local state |

## Reminders (`Services/Reminders/`)

| File | Type | Role |
|---|---|---|
| `EventKitSyncCoordinator.swift` | `EventKitSyncCoordinator` | Periodic EventKit pulls + change observer; cache fallback |
| `NotificationScheduler.swift` | `NotificationScheduler` | Per-event `UserNotifications` timers; posts `.showFullScreenAlert` when a meeting alert fires |

## Flat helpers

| File | Role |
|---|---|
| `CloudSyncService.swift`, `CloudSyncProtocols.swift`, `CloudServicesCoordinator.swift`, `CloudKitSyncMonitor.swift`, `FakeCloudServices.swift` | iCloud account state + sync progress facade; posts `.didFinishImport` and `.didReceiveRemoteChange` |
| `RemindersSyncService.swift` | Two-way bridge between `BacklogTask` and Apple Reminders |
| `BacklogLogic.swift` | Task prioritization helpers |
| `BacklogInteractionCoordinator.swift` | Coordinates UI mutations on backlog |
| `AutoDeferService.swift` | Rolls unfinished tasks forward to next workday |
| `TimelineSlotRanker.swift` | Ranks free slots for quick suggestions |
| `EnergyCheckInService.swift` | Energy level prompts and storage |
| `RecurrenceEngine.swift`, `RecurrenceExpander.swift` | Expands `RecurrenceRule` into occurrences |
| `UndoService.swift` | Undo stack for reversible actions (PRINCIPLES §5) |
| `QuickCaptureBridge.swift` | Buffer between hotkey overlay and `NewTaskView` |
| `PomodoroHistoryService.swift` | Pomodoro session log |
| `SlotPreviewCache.swift` | Caches free-slot proposals |
| `EventCache.swift` | In-memory hot cache for `upcomingEvents` |
| `NetworkMonitor.swift` | Reachability |
| `Keychain.swift` | Stores user-provided Anthropic API key |

## Conventions

- Services emit cross-cutting changes via `NotificationCenter` — see [`../concepts/notifications-bus.md`](../concepts/notifications-bus.md). Direct property reads use `@Observable` for tight UI binding.
- Construction is centralized in `AppContainer`. Do not `init()` a service in a view or another service ad-hoc; ask `AppContainer`.
- Heavy work (GA runs, network) is dispatched off the main actor; results are written back on `@MainActor`.
