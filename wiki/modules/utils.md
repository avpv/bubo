# Module: Utils

> **Kind:** module
> **Sources:** Bubo/Utils/
> **Last ingest:** 2026-05-11
> **Related:** [`services.md`](services.md), [`../concepts/recurrence.md`](../concepts/recurrence.md)

## Files

| File | Lines | Type+line | Role |
|---|---:|---|---|
| `ICalDateParser.swift` | 25 | `enum ICalDateParser` (`:5`) | iCalendar date string parser. Three formats supported: `yyyyMMdd'T'HHmmss'Z'` (UTC, "Z" suffix), `yyyyMMdd'T'HHmmss` (local), `yyyyMMdd` (date-only, 8 chars). Used by `RecurrenceRule` to parse UNTIL dates in RRULE strings |

If you find a candidate for this module, prefer a more specific home (a service-scoped helper next to its consumer) unless the helper is genuinely cross-cutting and stateless.
