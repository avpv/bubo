# Module: Models

> **Kind:** module
> **Sources:** Bubo/Models/Domain/, Bubo/Models/Persistence/
> **Last ingest:** 2026-05-11
> **Related:** [`../architecture/persistence.md`](../architecture/persistence.md), [`services.md`](services.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md)

## Layout

```
Models/
├── Domain/        # Plain Swift value types — the app's lingua franca
└── Persistence/   # @Model SwiftData mirrors of selected domain types
```

## Domain types

| File | Type(s) | Notes |
|---|---|---|
| `CalendarEvent.swift` | `CalendarEvent`, `EventColorTag`, `EventType`, `TaskStatus` | The wrapper around `EKEvent`. `EventType` includes a Pomodoro marker so timer events are distinguishable from regular meetings |
| `BacklogTask.swift` | `BacklogTask`, `Subtask`, `BacklogStatus` | Tasks the optimizer can place. Recurring rules, subtasks, markdown notes, URL/location fields, `modifiedAt` for cross-device merging |
| `ReminderSettings.swift` | `ReminderSettings`, `BadgeCountMode`, `PomodoroDefaults` | User preferences — calendars, colors, Pomodoro rhythm, energy hours, working hours, skin selection. Persists in UserDefaults + iCloud KVS |
| `RecurrenceRule.swift` | `RecurrenceRule` | Daily/weekly/monthly + exception dates |
| `PomodoroDefaults.swift` | `PomodoroPhase`, `PomodoroRhythm` | Five presets — see [`../concepts/pomodoro.md`](../concepts/pomodoro.md) |
| `EventPrepStore.swift` | `EventPrepOverride` | Saved customizations to meeting URL extraction |
| `WallpaperDefinition.swift` | `WallpaperCategory`, `Wallpaper` | Full-screen alert wallpaper metadata |

## Persistence mirrors

| File | `@Model` types | Container |
|---|---|---|
| `PersistedBacklogTask.swift` | `PersistedBacklogTask` | Backlog (CloudKit) |
| `PersistedEvent.swift` | `PersistedLocalEvent`, `PersistedExcludedOccurrence`, `PersistedReminderOverride`, `PersistedEventAttributeOverride`, `PersistedCachedEvent` | UserEvents (CloudKit) + EventCache (local) |

Mappings between `Persisted*` and the domain types live next to the stores in `Services/Persistence/`. Domain types are what services and views consume — `Persisted*` types do not escape the persistence layer.

## Why split Domain vs Persistence

- Domain types are `Sendable` value types; the GA needs hashable, deterministic input.
- SwiftData `@Model` classes are reference types tied to a `ModelContext`; passing them to background work is unsafe.
- The split lets the persistence schema evolve (add CloudKit-required fields, change relationships) without churning the domain surface views/services see.

## Test fakes

In-memory implementations of the persistence protocols live in `Services/Persistence/` and `Services/Apple/` (e.g. `FakeCalendarEventSource`). See [`tests.md`](tests.md).
