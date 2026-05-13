# Module: Models

> **Kind:** module
> **Sources:** Sources/BuboDomain/, Bubo/Infrastructure/Persistence/
> **Last ingest:** 2026-05-13 (rev: cross-references to `OptimizerModels.swift` rewritten — that file was split into per-type siblings on 2026-05-13; Domain content unchanged)
> **Related:** [`../architecture/persistence.md`](../architecture/persistence.md), [`../architecture/domain-boundaries.md`](../architecture/domain-boundaries.md), [`services.md`](services.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md), [`../concepts/recurrence.md`](../concepts/recurrence.md), [`../concepts/pomodoro.md`](../concepts/pomodoro.md)

## Layout

```
Sources/BuboDomain/           # 14 files — pure value types, their own SwiftPM target
├── Backlog/                  # BacklogTask + BacklogLogic
├── Calendar/                 # CalendarEvent + EventColorTag/EventType/TaskStatus,
│                             # Period, OptimizableEvent, EventPrepStore,
│                             # ICalDateParser, TimelineSlotRanker
├── Pomodoro/                 # PomodoroConfig + PomodoroDefaults
├── Recurrence/               # RecurrenceRule + RecurrenceEngine + RecurrenceExpander
└── Reminders/                # ReminderSettings + ReminderInterval/LocalProject/...

Bubo/Infrastructure/Persistence/   # 2 @Model SwiftData mirrors (lives in the Bubo target)
```

On 2026-05-12 the Domain layer was promoted from a `Bubo/Domain/` subfolder into a standalone `BuboDomain` SwiftPM target (see [`../architecture/layered-structure.md`](../architecture/layered-structure.md)). At the same time three types that had been parked under `Bubo/Optimizer/Models/` — `Period`, `PomodoroConfig`, `OptimizableEvent` — moved to Domain because Domain types already referenced them (the resulting cycle blocked target extraction). The old `Bubo/Models/` directory had been retired earlier; `Models/Domain/*` is now `Sources/BuboDomain/*` and `Models/Persistence/*` is `Bubo/Infrastructure/Persistence/`.

## Domain types

| File | Lines | Main type(s) | Notes |
|---|---:|---|---|
| `BacklogTask.swift` | 319 | `struct BacklogTask` (`:8`), `enum BacklogStatus`, `struct Subtask`, `enum TaskPriority` | Persistent task. Never consumed by the optimizer (carried across sessions). Fields include `title`, `durationMinutes`, `priority`, `deadline`, `storyPoints`, `context`, `colorTag: EventColorTag?` (`:20`), `dependsOn: [String]` (`:21`), `preferredPeriod: Period?` (`:22`, type lives in `Calendar/Period.swift`), `status`, `completedAt`, `createdAt`, `notes` (`:38`), `url: URL?` (`:44`), `location: String?` (`:49`), `subtasks: [Subtask]` (`:56`), `tags: [String]` (`:64`), `modifiedAt: Date?` (`:69`), `scheduledDate`/`scheduledEventId`/`scheduledEventIds` (`:73`,`:79`,`:86`), `isRecurring` + `recurrenceTag: String?` (`:32–33`). Notes/url/location/subtasks/tags round-trip through Apple Reminders' `notes` field via sentinel lines. The doc-comment at `:27–31` describes how `BacklogService.completeTask` and `RecurrenceEngine` cooperate to advance `deadline` on completion. `toOptimizableEvent(backlogIndex:)` (`:298`) converts the row into the optimizer's value type |
| `CalendarEvent.swift` | 482 | `enum EventColorTag` (`:10`), `enum EventType` (`:61`), `enum TaskStatus` (`:67`), `struct CalendarEvent` (`:73`), nested `struct TaskSequenceEntry` (`:186`), nested `struct PomodoroPhase` (`:388`) | Wrapper around `EKEvent` plus Bubo-specific fields. `EventColorTag.contextLabelsDefaultsKey` (`:16`) is the single source of truth for the `"BuboColorContextLabels"` UserDefaults key; `CloudSyncService.syncedKeys` references it via constant so renames stay consistent. The SwiftUI `Color` mapping lives in `Presentation/Views/Components/EventColorTag+Color.swift` so the domain stays pure (no `import SwiftUI`). `PomodoroPhase` is **nested inside `CalendarEvent`** and exposed via `currentPomodoroPhase(at:)` — describes *where in the work/break cycle* a Pomodoro event currently is. The 2026-05-12 BuboDomain extraction grew the file (+73 L) by adding explicit `public init`s for `CalendarEvent` and the nested `TaskSequenceEntry` — Swift's synthesized memberwise init is internal-by-default at module boundaries |
| `Calendar/OptimizableEvent.swift` | 85 | `struct OptimizableEvent` (`:10`) | The optimizer's value type for "something to schedule" — title, duration, deadline, priority, energy, preferred hour range, pomodoroConfig, reservedTaskIds, dependsOn, etc. **Moved from the (then-existing) `Bubo/Optimizer/Models/OptimizerModels.swift` to Domain on 2026-05-12** because `BacklogTask.toOptimizableEvent(...)` was already defined on a Domain type; keeping the conversion target in Optimizer/ produced a Domain↔Optimizer dependency cycle that blocked the multi-target split. (The Optimizer-side breadcrumb now lives in `Sources/BuboOptimizer/Models/ScheduleGene.swift` after the 2026-05-13 split of `OptimizerModels.swift` into per-type files) |
| `Calendar/Period.swift` | 36 | `enum Period` (`:11`) — `night`/`morning`/`afternoon`/`evening` | Time-of-day bucket. `hourRange` returns the closed range per case; `displayLabel` provides the human label used by pill controls. **Moved from `Bubo/Optimizer/Models/ScheduleTypes.swift` to Domain on 2026-05-12** because `BacklogTask.preferredPeriod`, the Intent DSL, and the Presentation period pickers all referenced it from outside Optimizer |
| `EventPrepStore.swift` | 102 | `enum EventPrepStore` (namespace) with `struct PrepEntry` | Per-event prep markdown scratchpad, keyed by event id. Single JSON-encoded `[String: PrepEntry]` blob in `UserDefaults` key `"BuboEventPrepNotes"`. Mirrored to iCloud KV via `CloudSyncService.shared.push`. Soft cap `maxEntries = 200` evicting oldest `updatedAt` first |
| `Pomodoro/PomodoroConfig.swift` | 32 | `struct PomodoroConfig` (`:11`) | Concrete shape of one pomodoro session — `workMinutes`/`breakMinutes`/`rounds`/`longBreakMinutes`, with derived `totalMinutes`. **Moved from the (then-existing) `Bubo/Optimizer/Models/OptimizerModels.swift` to Domain on 2026-05-12** because `CalendarEvent` stores a `pomodoroConfig: PomodoroConfig?`, `PersistedEvent` JSON-encodes it, and `PomodoroHistoryService` reads it — none of which sit inside Optimizer. (After the 2026-05-13 split, the Optimizer-side breadcrumb lives in `ScheduleGene.swift`) |
| `Pomodoro/PomodoroDefaults.swift` | 74 | `struct PomodoroDefaults` (`:19`) | **Smart-default generator only.** Given a target `durationMinutes`, suggests `(work, breakDur, rounds, longBreak)` using the canonical 25-min work / 5-min break ratio, fitting as many full rounds as possible (cap 8). Used by "Convert to Pomodoro". Does **not** contain named rhythm presets — those are docs-only (see [`../concepts/pomodoro.md`](../concepts/pomodoro.md)) |
| `RecurrenceRule.swift` | 363 | `struct RecurrenceRule` (`:5`), `enum RecurrenceFrequency` (`:241`), `enum RecurrenceEnd` (`:288`), `enum MonthlyMode` (`:296`), `enum Weekday` (`:305`) | RFC 5545-compatible rule for `CalendarEvent`. Adds Pomodoro-related fields (see `RecurrenceRule.swift` body) so a recurring event can carry Pomodoro intent |
| `ReminderSettings.swift` | 462 | `enum BadgeCountMode` (`:3`), `struct ReminderInterval` (`:17`), `struct LocalProject` (`:50`), `enum ActiveProject` (`:67`), `class ReminderSettings: Codable` (`:96`) | Active user preferences. `BadgeCountMode` has two cases: `.wholeDay`, `.timeWindow` (`:4–5`). `ReminderInterval` per-display non-breaking-space formatting (PRINCIPLES §3). Persisted in `UserDefaults`; mirrored to `NSUbiquitousKeyValueStore` for cross-device prefs. **Not** SwiftData. `ReminderSettings` is a `class` (not struct) — observable reference type used as `@State` in `BuboApp`. Stores `selectedWallpaperID: String`; the resolution to a `WallpaperDefinition` lives in `Presentation/Views/Skins/Wallpaper/ReminderSettings+Wallpaper.swift` to keep Domain free of SwiftUI types |

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
