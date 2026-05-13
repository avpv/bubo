# Module: Utils (retired)

> **Kind:** module
> **Sources:** (none — directory removed)
> **Last ingest:** 2026-05-12
> **Related:** [`../concepts/recurrence.md`](../concepts/recurrence.md), [`models.md`](models.md)

`Bubo/Utils/` no longer exists. Its single inhabitant moved to a more honest home:

| Old path | New path | Why |
|---|---|---|
| `Bubo/Utils/ICalDateParser.swift` | `Sources/Domain/Calendar/ICalDateParser.swift` | Pure value parser feeding `RecurrenceRule`; lives next to the domain type it serves |

Do not add new files under "Utils" — prefer a specific layer (`Domain`, `Infrastructure`, `Presentation`) or co-locate the helper with its consumer.
