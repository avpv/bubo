# Persistence architecture

> **Kind:** architecture
> **Sources:** Bubo/Composition/AppContainer.swift, Bubo/Infrastructure/Persistence/, Bubo/Infrastructure/Cloud/
> **Last ingest:** 2026-05-12
> **Related:** [`overview.md`](overview.md), [`../concepts/cloudkit-sync.md`](../concepts/cloudkit-sync.md), [`../modules/services.md`](../modules/services.md)

## Storage stacks

Three SwiftData `ModelContainer`s, configured in `AppContainer.swift`:

| Container | Models | CloudKit | Purpose |
|---|---|---|---|
| **EventCache** | `PersistedCachedEvent` | No (local only) | Offline read cache so the menu bar paints instantly at launch even before EventKit responds |
| **UserEvents** | `PersistedLocalEvent`, `PersistedExcludedOccurrence`, `PersistedReminderOverride`, `PersistedEventAttributeOverride` | Yes (private DB) | User-authored local events + per-event overlays that should sync across devices |
| **Backlog** | `PersistedBacklogTask` | Yes (private DB) | The backlog list — tasks the optimizer can place but EventKit cannot |

CloudKit-backed containers degrade gracefully: if the iCloud account is unavailable, `AppContainer.resilientContainer` (`AppContainer.swift:188`) rebuilds local-only. `CloudServicesCoordinator` (`Infrastructure/Cloud/CloudServicesCoordinator.swift`) monitors the account state and the SwiftData CloudKit completion notifications.

## Store protocols

`Infrastructure/Persistence/Stores.swift` declares the protocols views/services depend on. Each protocol has a concrete SwiftData impl and an in-memory fake for tests.

| Protocol | Concrete | What it owns |
|---|---|---|
| `LocalEventStoring` | `LocalEventStore` | Locally-created `CalendarEvent`s |
| `BacklogTaskStoring` | `BacklogTaskStore` | Backlog tasks (`PersistedBacklogTask`) |
| `ExcludedOccurrenceStoring` | `ExcludedOccurrenceStore` | Tombstones for individual occurrences of recurring events |
| `ReminderOverrideStoring` | `ReminderOverrideStore` | Per-event reminder count/offset overrides |
| `EventAttributeOverrideStoring` | `EventAttributeOverrideStore` | Per-event attribute overrides (color, etc.) |

## Sync

`EventKitSyncCoordinator` (in `Infrastructure/Reminders/`, not `Infrastructure/Persistence/` despite the name) runs periodic pulls from `EKEventStore` and merges with the SwiftData stores. `UpsertReconciler` (in `Infrastructure/Persistence/`) merges remote CloudKit imports with local state on `CloudKitSyncMonitor.didFinishImport`. `CloudKitSyncMonitor` itself lives in `Infrastructure/Cloud/`.

`RemindersSyncService` mirrors Bubo backlog tasks to/from Apple Reminders for users who opt in (two-way; see `Domain/Backlog/BacklogTask.swift` for the schema bridge).

## Settings persistence

`ReminderSettings` (in `Domain/Reminders/ReminderSettings.swift`) is **not** SwiftData — it lives in `UserDefaults` and is mirrored to `NSUbiquitousKeyValueStore` (via `CloudSyncService`) for cross-device sync of preferences (calendars selected, working hours, Pomodoro defaults, etc.).
