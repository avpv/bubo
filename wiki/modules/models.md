# Module: Models

> **Kind:** module
> **Sources:** Bubo/Domain/, Bubo/Infrastructure/Persistence/
> **Last ingest:** 2026-05-11 (rev: post-restructure)
> **Related:** [`../architecture/persistence.md`](../architecture/persistence.md), [`../architecture/domain-boundaries.md`](../architecture/domain-boundaries.md), [`services.md`](services.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md), [`../concepts/recurrence.md`](../concepts/recurrence.md), [`../concepts/pomodoro.md`](../concepts/pomodoro.md)

## Layout

```
Domain/                       # 12 files — plain Swift value types + pure namespaces
└── (7 former Models/Domain + 4 pure namespaces from Services + ICalDateParser)
Infrastructure/Persistence/
└── (2 @Model SwiftData mirrors alongside the SwiftData stores)
```

The old `Bubo/Models/` directory was retired in the layered refactor; `Models/Domain/*` moved to `Domain/` and `Models/Persistence/*` to `Infrastructure/Persistence/`.

## Domain types

| File | Lines | Main type(s) | Notes |
|---|---:|---|---|
| `BacklogTask.swift` | 318 | `struct BacklogTask` (`:8`), `enum BacklogStatus`, `struct Subtask`, `enum TaskPriority`, `enum Period` | Persistent task. Never consumed by the optimizer (carried across sessions). Fields include `title`, `durationMinutes`, `priority`, `deadline`, `storyPoints`, `context`, `colorTag: EventColorTag?` (`:20`), `dependsOn: [String]` (`:21`), `preferredPeriod` (`:22`), `status`, `completedAt`, `createdAt`, `notes` (`:37`), `url: URL?` (`:43`), `location: String?` (`:48`), `subtasks: [Subtask]` (`:55`), `tags: [String]` (`:63`), `modifiedAt: Date?` (`:68`), `scheduledDate`/`scheduledEventId`/`scheduledEventIds` (`:72–`), `isRecurring` + `recurrenceTag: String?` (`:31–32`). Notes/url/location/subtasks/tags round-trip through Apple Reminders' `notes` field via sentinel lines. The doc-comment at `:27–31` describes how `BacklogService.completeTask` and `RecurrenceEngine` cooperate to advance `deadline` on completion |
| `CalendarEvent.swift` | 408 | `enum EventColorTag` (`:7`), `enum EventType` (`:65`), `enum TaskStatus` (`:71`), `struct CalendarEvent` (`:77`), nested `struct PomodoroPhase` (`:334`) | Wrapper around `EKEvent` plus Bubo-specific fields. `EventColorTag.contextLabelsDefaultsKey` (`:13`) is the single source of truth for the `"BuboColorContextLabels"` UserDefaults key; `CloudSyncService.syncedKeys` references it via constant so renames stay consistent. The SwiftUI `Color` mapping lives in `Presentation/Views/Components/EventColorTag+Color.swift` so the domain stays pure (no `import SwiftUI`). `PomodoroPhase` is **nested inside `CalendarEvent`** and exposed via `currentPomodoroPhase(at:)` — describes *where in the work/break cycle* a Pomodoro event currently is |
| `EventPrepStore.swift` | 102 | `enum EventPrepStore` (namespace) with `struct PrepEntry` | Per-event prep markdown scratchpad, keyed by event id. Single JSON-encoded `[String: PrepEntry]` blob in `UserDefaults` key `"BuboEventPrepNotes"`. Mirrored to iCloud KV via `CloudSyncService.shared.push`. Soft cap `maxEntries = 200` evicting oldest `updatedAt` first |
| `PomodoroDefaults.swift` | 61 | `struct PomodoroDefaults` (`:19`) | **Smart-default generator only.** Given a target `durationMinutes`, suggests `(work, breakDur, rounds, longBreak)` using the canonical 25-min work / 5-min break ratio, fitting as many full rounds as possible (cap 8). Used by "Convert to Pomodoro". Does **not** contain named rhythm presets — those are docs-only (see [`../concepts/pomodoro.md`](../concepts/pomodoro.md)) |
| `RecurrenceRule.swift` | 363 | `struct RecurrenceRule` (`:5`), `enum RecurrenceFrequency` (`:241`), `enum RecurrenceEnd` (`:288`), `enum MonthlyMode` (`:296`), `enum Weekday` (`:305`) | RFC 5545-compatible rule for `CalendarEvent`. Adds Pomodoro-related fields (see `RecurrenceRule.swift` body) so a recurring event can carry Pomodoro intent |
| `ReminderSettings.swift` | 462 | `enum BadgeCountMode` (`:3`), `struct ReminderInterval` (`:17`), `struct LocalProject` (`:50`), `enum ActiveProject` (`:67`), `class ReminderSettings: Codable` (`:96`) | Active user preferences. `BadgeCountMode` has two cases: `.wholeDay`, `.timeWindow` (`:4–5`). `ReminderInterval` per-display non-breaking-space formatting (PRINCIPLES §3). Persisted in `UserDefaults`; mirrored to `NSUbiquitousKeyValueStore` for cross-device prefs. **Not** SwiftData. `ReminderSettings` is a `class` (not struct) — observable reference type used as `@State` in `BuboApp`. Stores `selectedWallpaperID: String`; the resolution to a `WallpaperDefinition` lives in `Presentation/Wallpaper/ReminderSettings+Wallpaper.swift` to keep Domain free of SwiftUI types |

## Persistence mirrors

| File | Lines | `@Model` types | Container | Notes |
|---|---:|---|---|---|
| `PersistedBacklogTask.swift` | 173 | `PersistedBacklogTask` (`:17`) | Backlog (CloudKit-optional) | All properties default-valued or optional — required by `NSPersistentCloudKitContainer`. Doc cites a fresh-`ModelContext`-per-operation policy adopted after threading hazards |
| `PersistedEvent.swift` | 327 | `PersistedLocalEvent` (`:21`), `PersistedCachedEvent` (`:145`), `PersistedExcludedOccurrence` (`:254`), `PersistedEventAttributeOverride` (`:275`), `PersistedReminderOverride` (`:295`) | UserEvents (CloudKit-optional) + EventCache (local) | Header doc notes CloudKit-backed models avoid `@Attribute(.unique)` because `NSPersistentCloudKitContainer` rejects unique constraints. Dedup is done in `ReminderService` via upsert. `updatedAt` set on every mutation so the post-import reconcile can pick the latest writer deterministically |

## Why split Domain vs Persistence

- Domain types are `Sendable` value types; the GA needs hashable, deterministic input.
- SwiftData `@Model` classes are reference types tied to a `ModelContext`; passing them to background work is unsafe.
- The split lets the persistence schema evolve (add CloudKit-required fields, change relationships) without churning the domain surface views/services see.
- All persistence models accept defaults or are optional — CloudKit mirroring requirement (see `PersistedEvent.swift:5–17`).

## Test fakes

In-memory implementations of the persistence protocols live in `Infrastructure/Persistence/InMemoryStores.swift`. In-memory `CalendarEventSource` / `RemindersEventSource` fakes live next to the protocols under `Infrastructure/Apple/`.
