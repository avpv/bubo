# Module: Utils

> **Kind:** module
> **Sources:** Bubo/Utils/
> **Last ingest:** 2026-05-11
> **Related:** [`services.md`](services.md)

## Files

| File | Role |
|---|---|
| `ICalDateParser.swift` | Parses iCalendar date/time strings (RFC 5545: `DTSTART`, `EXDATE`, etc.) — used by the recurrence engine and any code importing raw iCal payloads |

If you find a candidate for this module, prefer a more specific home (a service-scoped helper next to its consumer) unless the helper is genuinely cross-cutting and stateless.
