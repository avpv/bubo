# Module: Models

> **Kind:** module
> **Sources:** Bubo/Models/Domain/, Bubo/Models/Persistence/
> **Last ingest:** 2026-05-11
> **Related:** [`../architecture/persistence.md`](../architecture/persistence.md), [`services.md`](services.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md), [`../concepts/recurrence.md`](../concepts/recurrence.md), [`../concepts/pomodoro.md`](../concepts/pomodoro.md)

## Layout

```
Models/
├── Domain/        # 7 files — plain Swift value types — the app's lingua franca
└── Persistence/   # 2 files — @Model SwiftData mirrors of selected domain types
```

## Domain types

| File | Lines | Main type(s) | Notes |
|---|---:|---|---|
| `BacklogTask.swift` | 318 | `struct BacklogTask` (`:8`), `enum BacklogStatus`, `struct Subtask`, `enum TaskPriority` | Persistent task. Never consumed by the optimizer (carried across sessions). Fields: `title`, `durationMinutes`, `priority`, `deadline`, `storyPoints`, `context`, `colorTag: EventColorTag?`, `dependsOn: [String]`, `preferredPeriod`, `status`, `completedAt`, `createdAt`, `notes`, `url: URL?` (`:43`), `location: String?` (`:48`), `isRecurring` + `recurrenceTag: String?` (`:30`). Round-trips through Apple Reminders' `notes` field |
| `CalendarEvent.swift` | 413 | `enum EventColorTag` (`:7`), `struct CalendarEvent`, `enum EventType`, `enum TaskStatus`, `struct PomodoroPhase` (`:334`) | Wrapper around `EKEvent` plus Bubo-specific fields. `EventColorTag` has user-configurable `contextLabel` persisted in `UserDefaults` at key `"BuboColorContextLabels"` (`:26`). `PomodoroPhase` and `currentPomodoroPhase(at:)` (`:355`) live inside this file — they describe *where in the work/break cycle* a Pomodoro event currently is |
| `EventPrepStore.swift` | 102 | `enum EventPrepStore` (namespace) with `struct PrepEntry` | Per-event prep markdown scratchpad, keyed by event id. Single JSON-encoded `[String: PrepEntry]` blob in `UserDefaults` key `"BuboEventPrepNotes"`. Mirrored to iCloud KV via `CloudSyncService.shared.push`. Soft cap `maxEntries = 200` evicting oldest `updatedAt` first |
| `PomodoroDefaults.swift` | 61 | `struct PomodoroDefaults` (`:19`) | **Smart-default generator only.** Given a target `durationMinutes`, suggests `(work, breakDur, rounds, longBreak)` using the canonical 25-min work / 5-min break ratio, fitting as many full rounds as possible (cap 8). Used by "Convert to Pomodoro". Does **not** contain named rhythm presets — those are docs-only (see [`../concepts/pomodoro.md`](../concepts/pomodoro.md)) |
| `RecurrenceRule.swift` | 363 | `struct RecurrenceRule` (`:5`), `enum RecurrenceFrequency`, `enum RecurrenceEnd`, `enum Weekday`, `enum MonthlyMode` | RFC 5545-compatible rule for `CalendarEvent`. Adds `pomodoroMode: Bool` and `pomodoroLongBreak: Int` (`:11–14`) so a recurring event can carry Pomodoro intent |
| `ReminderSettings.swift` | 462 | `struct ReminderSettings`, `enum BadgeCountMode` (`:3`), `struct ReminderInterval` (`:17`), plus other enums | Active user preferences. `BadgeCountMode` has two cases: `.wholeDay`, `.timeWindow` (`:4–5`). `ReminderInterval` uses non-breaking spaces in display text per PRINCIPLES §3 (`:36`). Persisted in `UserDefaults`; mirrored to `NSUbiquitousKeyValueStore` for cross-device prefs. **Not** SwiftData |
| `WallpaperDefinition.swift` | 304 | `enum WallpaperCategory` (`:5`) — `.solidColor`, `.gradient`, `.pattern`, `.live`. `struct WallpaperDefinition` (`:33`) | Background metadata for the full-screen alert |

## Persistence mirrors

| File | Lines | `@Model` types | Container | Notes |
|---|---:|---|---|---|
| `PersistedBacklogTask.swift` | 173 | `PersistedBacklogTask` (`:17`) | Backlog (CloudKit-optional) | All properties default-valued or optional — required by `NSPersistentCloudKitContainer`. Doc cites a fresh-`ModelContext`-per-operation policy adopted after threading hazards in v1.10.30–v1.10.41 |
| `PersistedEvent.swift` | 327 | `PersistedLocalEvent` (`:23`), `PersistedExcludedOccurrence`, `PersistedReminderOverride`, `PersistedEventAttributeOverride`, `PersistedCachedEvent` | UserEvents (CloudKit-optional) + EventCache (local) | Doc at `:5–17` notes CloudKit-backed models avoid `@Attribute(.unique)` because `NSPersistentCloudKitContainer` rejects unique constraints. Dedup is done in `ReminderService` via upsert (fetch by logical key, update in place, otherwise insert). `updatedAt` set on every mutation so the post-import reconcile can pick the latest writer deterministically |

## Why split Domain vs Persistence

- Domain types are `Sendable` value types; the GA needs hashable, deterministic input.
- SwiftData `@Model` classes are reference types tied to a `ModelContext`; passing them to background work is unsafe.
- The split lets the persistence schema evolve (add CloudKit-required fields, change relationships) without churning the domain surface views/services see.
- All persistence models accept defaults or are optional — CloudKit mirroring requirement (see `PersistedEvent.swift:5–17`).

## Test fakes

In-memory implementations of the persistence protocols live in `Services/Persistence/InMemoryStores.swift`. In-memory `CalendarEventSource` / `RemindersEventSource` fakes live next to the protocols under `Services/Apple/`.
