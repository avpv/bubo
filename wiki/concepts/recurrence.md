# Recurrence

> **Kind:** concept
> **Sources:** Bubo/Services/RecurrenceEngine.swift, Bubo/Services/RecurrenceExpander.swift, Bubo/Models/Domain/RecurrenceRule.swift, Bubo/Models/Domain/BacklogTask.swift, Bubo/Models/Domain/CalendarEvent.swift, Bubo/Services/Persistence/ExcludedOccurrenceStore.swift, Bubo/Utils/ICalDateParser.swift
> **Last ingest:** 2026-05-11
> **Related:** [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md), [`../modules/services.md`](../modules/services.md), [`../modules/models.md`](../modules/models.md)

## Two recurrence systems, not one

Bubo has **two unrelated recurrence implementations** because tasks and events recur differently:

| | Tasks | Events |
|---|---|---|
| Input | `BacklogTask.recurrenceTag` (free-form string) | `CalendarEvent.recurrenceRule` (`RecurrenceRule` struct) |
| Engine | `RecurrenceEngine` (`Services/RecurrenceEngine.swift`) | `RecurrenceExpander` (`Services/RecurrenceExpander.swift`) |
| Output | Next single occurrence date | Array of occurrences in a window |
| Strictness | Forgiving substring match | RFC 5545 frequency types |
| Trigger | `BacklogService.completeTask` reschedules the row | Read-path expansion every time events are surfaced |

Confusing them is the most likely refactor mistake.

## Task recurrence (`RecurrenceEngine`)

The user writes a free-form tag like `"daily"`, `"weekly review"`, `"monthly report"`. `RecurrenceEngine.frequency(for:)` (`RecurrenceEngine.swift:38`) maps it to a coarse bucket: `.daily`, `.weekly`, `.biweekly`, `.monthly`, `.quarterly`, `.yearly`, `.unknown`. Matching is case-insensitive substring; English keywords first, plus a few Russian equivalents. Unknown → treated as `.daily`.

Why the looseness: tag strings are user-authored prose, not structured input. The cost of a wrong match is one day's misalignment, which the user trivially corrects.

The engine produces a sensible next `deadline` after a task completes; `BacklogService.completeTask` writes the new date and posts `.taskScheduleChanged`.

## Event recurrence (`RecurrenceExpander`)

Operates on `CalendarEvent.recurrenceRule` (`RecurrenceRule` in `Models/Domain/RecurrenceRule.swift`). Strict RFC 5545 frequency types — `.minutely`, `.hourly`, `.daily`, `.weekly`, `.monthly`, `.yearly`.

`RecurrenceExpander.expand(_:windowEnd:excludedIds:excludedDates:)` (`RecurrenceExpander.swift:9`) returns occurrences within a window. The window end defaults to `rule.expansionWindowDays` from today. Each occurrence carries the duration `end - start` of the base event.

End conditions on the rule:

- `.afterCount(n)` — emit at most `n` occurrences.
- `.untilDate(d)` — stop when the cursor passes `d`.

There is also a per-frequency hard limit to prevent runaway expansion (`RecurrenceExpander.swift:33` and around): `.minutely` 10 080, `.hourly` 168, `.daily` 365, `.weekly` 520, `.monthly` 120, `.yearly` 50.

## Excluded occurrences (event tombstones)

When the user deletes a single instance of a recurring event, the system stores a tombstone in `ExcludedOccurrenceStore` (`Services/Persistence/ExcludedOccurrenceStore.swift`) instead of mutating the series. `RecurrenceExpander.expand` skips matching ids/dates. Two skip mechanisms exist:

- `excludedIds: Set<String>` — for local event exclusions (Bubo-authored series).
- `excludedDates: Set<Date>` — same-day match for iCal `EXDATE` lines parsed by `ICalDateParser` (`Bubo/Utils/ICalDateParser.swift`).

## iCal parsing

`ICalDateParser` (`Bubo/Utils/ICalDateParser.swift`) is the sole parser for raw iCal date payloads. Used by the recurrence expander when consuming imported EXDATE/RDATE lines.

## When NOT to expand

The expander returns `[event]` unchanged if `recurrenceRule` is nil. Single events take the fast path.

## Where this surfaces

- `EventKitSyncCoordinator` calls `RecurrenceExpander` after each pull so consumers see flat lists of occurrences, not series.
- `OptimizerService` consumes the flat list — the GA never sees recurrence rules directly.
- `BacklogService.completeTask` calls `RecurrenceEngine.frequency(for:)` to roll a recurring task forward.
