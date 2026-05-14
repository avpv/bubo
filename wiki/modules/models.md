# Module: Models

> **Kind:** module
> **Sources:** Sources/Domain/, Bubo/Infrastructure/Persistence/
> **Last ingest:** 2026-05-14 (rev: line citations for `CalendarEvent.swift` (+3) and `RecurrenceRule.swift` (+13) resynced; layout block updated for 16 Domain files; rows added for `BacklogLogic`, `AdjustedEnergy`, `TimelineSlotRanker`, `RecurrenceEngine`, `RecurrenceExpander`, `DomainCloudSync`; file line counts refreshed)
> **Related:** [`../architecture/persistence.md`](../architecture/persistence.md), [`../architecture/domain-boundaries.md`](../architecture/domain-boundaries.md), [`services.md`](services.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md), [`../concepts/recurrence.md`](../concepts/recurrence.md), [`../concepts/pomodoro.md`](../concepts/pomodoro.md)

## Layout

```
Sources/Domain/           # 16 files — pure value types, their own SwiftPM target
├── Backlog/                  # BacklogTask + BacklogLogic
├── Calendar/                 # CalendarEvent (+EventColorTag/EventType/TaskStatus),
│                             # Period, OptimizableEvent, EventPrepStore,
│                             # ICalDateParser, TimelineSlotRanker, AdjustedEnergy
├── Pomodoro/                 # PomodoroConfig + PomodoroDefaults
├── Recurrence/               # RecurrenceRule + RecurrenceEngine + RecurrenceExpander
├── Reminders/                # ReminderSettings + ReminderInterval/LocalProject/...
└── Sync/                     # DomainCloudSync (cross-target Notification.Name bridge)

Bubo/Infrastructure/Persistence/   # 2 @Model SwiftData mirrors (lives in the Bubo target)
```

On 2026-05-12 the Domain layer was promoted from a `Bubo/Domain/` subfolder into a standalone `BuboDomain` SwiftPM target (see [`../architecture/layered-structure.md`](../architecture/layered-structure.md)). At the same time three types that had been parked under `Bubo/Optimizer/Models/` — `Period`, `PomodoroConfig`, `OptimizableEvent` — moved to Domain because Domain types already referenced them (the resulting cycle blocked target extraction). The old `Bubo/Models/` directory had been retired earlier; `Models/Domain/*` is now `Sources/Domain/*` and `Models/Persistence/*` is `Bubo/Infrastructure/Persistence/`.

## Domain types

| File | Lines | Main type(s) | Notes |
|---|---:|---|---|
| `Backlog/BacklogTask.swift` | 319 | `struct BacklogTask` (`:8`), `struct Subtask` (`:162`), `enum TaskPriority` (`:187`), `enum BacklogStatus` (`:211`) | Persistent task. Never consumed by the optimizer (carried across sessions). Fields include `title`, `durationMinutes`, `priority`, `deadline`, `storyPoints`, `context`, `colorTag: EventColorTag?` (`:20`), `dependsOn: [String]` (`:21`), `preferredPeriod: Period?` (`:22`, type lives in `Calendar/Period.swift`), `status`, `completedAt`, `createdAt`, `notes` (`:38`), `url: URL?` (`:44`), `location: String?` (`:49`), `subtasks: [Subtask]` (`:56`), `tags: [String]` (`:64`), `modifiedAt: Date?` (`:69`), `scheduledDate`/`scheduledEventId`/`scheduledEventIds` (`:73`,`:79`,`:86`), `isRecurring` + `recurrenceTag: String?` (`:32–33`). Notes/url/location/subtasks/tags round-trip through Apple Reminders' `notes` field via sentinel lines. The doc-comment at `:24–31` describes how `BacklogService.completeTask` and `RecurrenceEngine` cooperate to advance `deadline` on completion. `toOptimizableEvent(backlogIndex:)` (`:298`) converts the row into the optimizer's value type |
| `Backlog/BacklogLogic.swift` | 414 | `enum BacklogLogic` (`:14`) — pure-function namespace | Smart-sort, urgent-filter and capacity math extracted from `BacklogView` so they can be tested without a SwiftUI host (`:5–11`). All helpers take an injected `now: Date` for determinism; the view delegates its computed properties to these functions |
| `Calendar/CalendarEvent.swift` | 485 | `enum EventColorTag` (`:10`), `enum EventType` (`:64`), `enum TaskStatus` (`:70`), `struct CalendarEvent` (`:76`), nested `struct TaskSequenceEntry` (`:189`), nested `struct PomodoroPhase` (`:391`) | Wrapper around `EKEvent` plus Bubo-specific fields. `EventColorTag.contextLabelsDefaultsKey` (`:16`) is the single source of truth for the `"BuboColorContextLabels"` UserDefaults key; `CloudSyncService.syncedKeys` references it via constant so renames stay consistent. The SwiftUI `Color` mapping lives in `Presentation/Views/Components/EventColorTag+Color.swift` so the domain stays pure (no `import SwiftUI`). `PomodoroPhase` is **nested inside `CalendarEvent`** and exposed via `currentPomodoroPhase(at:)` (`:427`) — describes *where in the work/break cycle* a Pomodoro event currently is. The 2026-05-12 BuboDomain extraction added explicit `public init`s for `CalendarEvent` and the nested `TaskSequenceEntry` because Swift's synthesized memberwise init is internal-by-default at module boundaries |
| `Calendar/OptimizableEvent.swift` | 85 | `struct OptimizableEvent` (`:10`) | The optimizer's input value type — title, duration, deadline, priority, energy, preferred hour range, pomodoroConfig, reservedTaskIds, dependsOn, etc. Doc-comment at `:6–9` records that it lives in Domain (not Optimizer) so the `BacklogTask.toOptimizableEvent()` converter doesn't form a Domain↔Optimizer cycle |
| `Calendar/Period.swift` | 36 | `enum Period` (`:11`) — `night`/`morning`/`afternoon`/`evening` | Time-of-day bucket. `hourRange` returns the closed range per case; `displayLabel` provides the human label used by pill controls. Doc-comment at `:6–10` records the cycle-break reason for living in Domain |
| `Calendar/EventPrepStore.swift` | 111 | `enum EventPrepStore` (`:23`) with nested `struct PrepEntry` (`:27`) | Per-event prep markdown scratchpad, keyed by event id. Single JSON-encoded `[String: PrepEntry]` blob in `UserDefaults` key `"BuboEventPrepNotes"`. Mirrored to iCloud KV via `CloudSyncService.shared.push`. Soft cap `maxEntries = 200` evicting oldest `updatedAt` first (see header doc `:3–20`) |
| `Calendar/ICalDateParser.swift` | 25 | `enum ICalDateParser` (`:5`) with `static func parse(_:)` | iCal date parser for RFC 5545 `UNTIL`/`EXDATE` payloads. Handles `yyyyMMdd'T'HHmmss'Z'`, `yyyyMMdd'T'HHmmss`, and bare `yyyyMMdd`. Used by `RecurrenceRule` decoding |
| `Calendar/TimelineSlotRanker.swift` | 244 | `enum TimelineSlotRanker` (`:16`) with nested `struct SlotContext` (`:19`), `struct Score`, ranking helpers | Pure-logic ranker that orders backlog tasks for placement into a specific timeline slot. Used by `SlotPickerPopover`. Header at `:1–14` records the ordering: urgent → fits-the-slot → matches-neighbouring-project → matches-preferred-period → most-recently-created. Weights are hand-tuned in `Score.total` |
| `Calendar/AdjustedEnergy.swift` | 14 | `public func adjustedEnergy(base:storyPoints:)` (`:8`) | Free function that scales base energy by story points (logarithmic on log(13)). Lives in Domain so `BacklogTask.toOptimizableEvent()` can call it without forming an upward dependency on `BuboOptimizer` (`:4–7`) |
| `Pomodoro/PomodoroConfig.swift` | 32 | `struct PomodoroConfig` (`:11`) | Concrete shape of one pomodoro session — `workMinutes`/`breakMinutes`/`rounds`/`longBreakMinutes`, with derived `totalMinutes`. Doc-comment at `:5–9` records the cycle-break reason for living in Domain (consumed by `CalendarEvent`, `PersistedEvent`, `PomodoroHistoryService`) |
| `Pomodoro/PomodoroDefaults.swift` | 74 | `struct PomodoroDefaults` (`:19`) | **Smart-default generator only.** Given a target `durationMinutes`, suggests `(work, breakDur, rounds, longBreak)` using the canonical 25-min work / 5-min break ratio, fitting as many full rounds as possible (cap 8). Used by "Convert to Pomodoro". Does **not** contain named rhythm presets — those are docs-only (see [`../concepts/pomodoro.md`](../concepts/pomodoro.md)) |
| `Recurrence/RecurrenceRule.swift` | 376 | `struct RecurrenceRule` (`:5`), `enum RecurrenceFrequency` (`:254`), `enum RecurrenceEnd` (`:301`), `enum MonthlyMode` (`:309`), `enum Weekday` (`:318`) | RFC 5545-compatible rule for `CalendarEvent`. Includes `pomodoroMode: Bool` (`:15`) and `pomodoroLongBreak: Int` (`:17`) so a recurring event can carry Pomodoro intent |
| `Recurrence/RecurrenceEngine.swift` | 84 | `enum RecurrenceEngine` (`:15`), nested `enum Frequency` (`:18`) | Free-form-tag → next-occurrence engine for `BacklogTask`. `frequency(for:)` (`:33`) maps a free-form `recurrenceTag` to a coarse bucket (case-insensitive substring); `nextOccurrence(after:tag:calendar:)` (`:66`) returns the next deadline. Doc-comment at `:1–14` explains forgiving substring matching and the `.unknown → .daily` fallback |
| `Recurrence/RecurrenceExpander.swift` | 316 | `enum RecurrenceExpander` (`:6`) | RFC 5545 expander for `CalendarEvent`. `expand(_:windowEnd:excludedIds:excludedDates:)` (`:14`) returns occurrences within a window; falls back to `[event]` for non-recurring inputs. Per-frequency safety caps live in the closure at `:33` (e.g. `.daily 365`, `.weekly 520`) |
| `Reminders/ReminderSettings.swift` | 451 | `enum BadgeCountMode` (`:3`), `struct ReminderInterval` (`:17`), `struct LocalProject` (`:50`), `enum ActiveProject` (`:67`), `class ReminderSettings: Codable` (`:96`) | Active user preferences. `BadgeCountMode` has two cases: `.wholeDay`, `.timeWindow` (`:4–5`). `ReminderInterval` per-display non-breaking-space formatting (PRINCIPLES §3). Persisted in `UserDefaults`; mirrored to `NSUbiquitousKeyValueStore` for cross-device prefs. **Not** SwiftData. `ReminderSettings` is a `class` (not struct) — observable reference type used as `@State` in `BuboApp`. Stores `selectedWallpaperID: String`; the resolution to a `WallpaperDefinition` lives in `Presentation/Views/Skins/Wallpaper/ReminderSettings+Wallpaper.swift` to keep Domain free of SwiftUI types |
| `Sync/DomainCloudSync.swift` | 28 | `enum DomainCloudSync` (`:10`) with two `Notification.Name` constants | Cross-target Notification.Name bridge: BuboDomain types post `shouldPushKey` after a synced UserDefaults write, and observe `didReceiveRemoteChange` after `CloudSyncService` in the `Bubo` target merges remote KV data. Keeps BuboDomain from referencing `CloudSyncService` directly (`:4–9`) |

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
