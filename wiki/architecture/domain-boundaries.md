# Domain boundaries

> **Kind:** architecture
> **Sources:** Package.swift, Sources/Domain/, Sources/Domain/Reminders/README.md, Sources/Domain/Calendar/Period.swift, Sources/Domain/Calendar/OptimizableEvent.swift, Sources/Domain/Pomodoro/PomodoroConfig.swift, Sources/Optimizer/, Sources/Optimizer/README.md, Sources/Optimizer/Models/, Sources/Optimizer/Models/EventConversion.swift, Sources/Optimizer/Models/ScheduleGene.swift, Sources/Optimizer/Models/OptimizerContext.swift, Sources/Optimizer/Models/OptimizerPreferences.swift, Sources/Optimizer/Models/OptimizerResult.swift
> **Last ingest:** 2026-05-14 (rev: fixed stale "Pomodoro is dual-citizen" line — `PomodoroConfig` lives in `Sources/Domain/Pomodoro/`, not `Sources/Optimizer/Models/`; both Pomodoro types are Domain-side, no dual citizenship)
> **Related:** [`layered-structure.md`](layered-structure.md), [`../modules/models.md`](../modules/models.md), [`../modules/optimizer.md`](../modules/optimizer.md)

The codebase has two distinct "domain model" folders. This document
defines what belongs in each and how they relate, because the naming
("Domain" vs "Optimizer/Models") doesn't make the distinction obvious.

Since 2026-05-12 the boundary is also compiler-enforced: `BuboDomain` is its own SwiftPM target and `BuboOptimizer` declares it as a dependency. Code in `Sources/Optimizer/Models/` can `import BuboDomain` but Domain cannot reach back the other way.

## TL;DR

| Folder | Target | What lives here | Imported by |
|---|---|---|---|
| `Sources/Domain/` | `BuboDomain` | The user-facing domain. Types the rest of the app stores, displays, and edits. **As of 2026-05-12 also holds the GA's input value types** (`OptimizableEvent`, `Period`, `PomodoroConfig`) because Domain types reference them and keeping them in Optimizer formed the dependency cycle. | Every other target (`BuboOptimizer`, `Bubo`). |
| `Sources/Optimizer/Models/` | `BuboOptimizer` | The optimizer-internal types: `ScheduleGene`, `ScheduleScenario`, `ScheduleSnapshot`, `AppliedSnapshot`, `OptimizerContext`, `OptimizerPreferences`, `Horizon`, `Speed`, `Stability`, `WeightKey`, `EventMatch`, `EventSpec`, etc. Plus `EventConversion.swift` (the bridge). `ActionableResolution`, `OptimizationResult`, and `AppliedRequestSummary` moved to `Bubo/Application/Optimizer/OptimizationResult.swift` in PR #516 (now internal Bubo types). | Only the rest of `BuboOptimizer`. The `Bubo` target consumes `OptimizerResult` / `AppliedSnapshot` etc. via `OptimizerService`. |

## `Sources/Domain/` — the app's domain

The single source of truth for everything the user *creates*, *sees*,
or *persists*. Types here are:

- **Stable** — schema changes here ripple to CloudKit, SwiftData
  migrations, and view code. Treat as a versioned contract.
- **Identity-rich** — `CalendarEvent`, `BacklogTask`, `RecurrenceRule`
  carry IDs, timestamps, color tags, calendar references, project
  bindings, etc.
- **Framework-light** — Foundation + Observation only. No SwiftUI, no
  AppKit, no CloudKit, no SwiftData (those live in
  `Infrastructure/Persistence/` as `@Model` mirrors).
- **Pure namespaces** (`enum`-based): `BacklogLogic`,
  `RecurrenceEngine`, `RecurrenceExpander`, `TimelineSlotRanker`.

Examples: `BacklogTask`, `CalendarEvent`, `RecurrenceRule`,
`ReminderSettings`, `PomodoroDefaults`, `EventPrepStore`,
`ICalDateParser`, plus the three 2026-05-12 arrivals from Optimizer:
`Period` (time-of-day bucket on `BacklogTask`), `PomodoroConfig`
(stored on `CalendarEvent`, JSON-persisted by `PersistedEvent`), and
`OptimizableEvent` (the bridge value type — `BacklogTask` already had a
`toOptimizableEvent()` converter that made co-locating them necessary).

## `Sources/Optimizer/Models/` — the optimizer's internal types

The GA-internal model layer. Types here are:

- **Computational** — `ScheduleGene`, `ScheduleScenario`,
  `OptimizerContext`, etc. Carry only the fields the fitness functions,
  constraints, and operators actually read.
- **`Sendable`-strict** — value types with no observation, no
  references back to UI state. Required because the GA fans work out
  across `Task`s and the island model needs deterministic input.
- **Optimizer-internal** — nothing outside `Sources/Optimizer/`
  should import these directly. Application code that wants to drive
  the optimizer passes `CalendarEvent`/`BacklogTask` (Domain types) and
  lets `EventConversion` translate at the boundary.
- **Free to evolve** — adding a field to `OptimizerContext` doesn't
  break persistence or the UI. That's the whole point of the
  separation.

Files (post 2026-05-13):
- `ScheduleGene.swift` — `struct ScheduleGene` (the gene type the GA
  mutates). The earlier `OptimizableEvent` + `PomodoroConfig`
  definitions were lifted into `BuboDomain` on 2026-05-12 to break the
  dependency cycle; this file inherited the breadcrumb comments at the
  top pointing at the new homes when the 676-line `OptimizerModels.swift`
  was split into per-type files on 2026-05-13.
- `OptimizerContext.swift` — `struct OptimizerContext` (the GA's frozen
  input snapshot).
- `OptimizerPreferences.swift` — `struct OptimizerPreferences` (weights
  + structural knobs). Public default values via `defaultBacklogOrderWeight`,
  `defaultDayCompactnessWeight`, `defaultWorkingDays`, `defaultBufferMinutes`.
- `OptimizerResult.swift` — `OptimizerResult`, `ScheduleScenario`,
  `OptimizationMetadata`, `UserFeedback`.
- `ScheduleTypes.swift` — `Horizon`, `Speed`, `Stability`, `WeightKey`,
  `HourRange`, `EventSpec`, `EventSegment`, `EventMatch`,
  `ScheduleSnapshot`, `AppliedSnapshot`, and others. All still
  public BuboOptimizer types. `Period` used to live here — it moved to
  `Sources/Domain/Calendar/Period.swift`. `ActionableResolution`,
  `OptimizationResult`, and `AppliedRequestSummary` moved to
  `Bubo/Application/Optimizer/OptimizationResult.swift` in PR #516 —
  they are now internal Bubo types (no longer public BuboOptimizer surface).
- `EventConversion.swift` — the only bridge. Defines extensions on
  `CalendarEvent` / `BacklogTask` that materialize `OptimizableEvent`.
  Since `OptimizableEvent` now lives in Domain too, the bridge is a
  one-line `import BuboDomain` away from Domain types on both sides.
- `TaskSignature.swift` — hash key for component-fitness caching.

## The bridge: `EventConversion`

`Sources/Optimizer/Models/EventConversion.swift` is the **only** file
that knows about both worlds. It defines extensions on
`CalendarEvent` and `BacklogTask` that materialize their
`OptimizableEvent` projections.

Direction matters: conversion goes **app domain → optimizer domain**.
The optimizer returns its results as a separate type
(`ScheduleGene` / `ScheduleScenario`) which is then mapped *back* into
`CalendarEvent` mutations by `OptimizerService`. There is no
reverse `OptimizableEvent.toCalendarEvent()` — by design.

Since 2026-05-12, `OptimizableEvent` lives in `BuboDomain` (`Sources/Domain/`) rather than
in `Sources/Optimizer/Models/`. The bridge file still does the conversion
work, just from one Domain type to another (`BacklogTask` →
`OptimizableEvent`); the GA reads `OptimizableEvent` directly through
its `import BuboDomain`.

## Why two folders, not one

History: in 2026 these lived together under a flat `Models/`
folder. They were split because:

1. **The GA needs to be hermetic.** Pulling in `CalendarEvent` (with
   its EventKit identifiers, recurrence cache, color metadata) made
   `OptimizableEvent` a leaky abstraction and slowed serialization
   in the island model.
2. **The app domain needs to evolve independently.** Adding a
   "spent_pomodoro_count" field to `BacklogTask` shouldn't force a
   reload of every fitness benchmark.
3. **Tests want to stub one side without the other.** Unit tests for
   `BacklogLogic` use raw `BacklogTask` values; GA tests synthesize
   `OptimizableEvent` directly.

The 2026-05-12 BuboOptimizer extraction added a fourth reason: **target
isolation.** Optimizer-internal types are now in a separate SwiftPM
module, so Application/Presentation code physically cannot reach into
`ScheduleGene` or `OptimizerContext` — those types aren't `public`. The
boundary is no longer "we agreed not to import"; it's "the compiler
will reject the import".

## In-tree boundary READMEs

The 2026-05-12 layer-leak cleanup added two short READMEs that codify
the rules at the folder level:

- `Sources/Domain/Reminders/README.md` — what each Reminders layer
  (Domain/Application/Infrastructure) owns; explicitly lists the
  framework imports forbidden at each layer.
- `Sources/Optimizer/README.md` — why `Optimizer/` lives as a peer of
  `Domain/` rather than under it, the per-subfolder map, and the
  no-EventKit / no-SwiftUI rule for engine files.

Both are excluded from the SPM `Bubo` target build via the
`Package.swift` exclude list so they don't trigger SwiftPM "unhandled
resource" warnings.

## Rules

- New computational fields the GA wants → `Optimizer/Models/`.
- New user-facing or persisted fields → `Sources/Domain/`. Then extend
  `EventConversion` if the GA also needs to read it.
- Never `import` from `Optimizer/Models/` outside the
  `Sources/Optimizer/` subtree. The composition root and application
  services consume the app domain only.
- Pomodoro types both live in `Sources/Domain/Pomodoro/`:
  `PomodoroDefaults.swift` (smart-default generator) and
  `PomodoroConfig.swift` (the per-event compiled shape the GA reads).
  `PomodoroConfig` is stored on `CalendarEvent` and JSON-persisted by
  `PersistedEvent`, so it must live below the optimizer.
