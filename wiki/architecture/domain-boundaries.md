# Domain boundaries

> **Kind:** architecture
> **Sources:** Bubo/Domain/, Bubo/Optimizer/Models/, Bubo/Optimizer/Models/EventConversion.swift
> **Last ingest:** 2026-05-12 (rev: bounded-context restructure + mega-file split)
> **Related:** [`layered-structure.md`](layered-structure.md), [`../modules/models.md`](../modules/models.md)

The codebase has two distinct "domain model" folders. This document
defines what belongs in each and how they relate, because the naming
("Domain" vs "Optimizer/Models") doesn't make the distinction obvious.

## TL;DR

| Folder | What lives here | Imported by |
|---|---|---|
| `Bubo/Domain/` | The user-facing domain. Types the rest of the app stores, displays, and edits. | Every layer (Application, Infrastructure, Presentation, Optimizer). |
| `Bubo/Optimizer/Models/` | The optimizer-facing domain. Types the GA reads, scores, and mutates. | Optimizer only. Other layers must convert to/from these via `EventConversion`. |

## `Bubo/Domain/` — the app's domain

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
`ICalDateParser`.

## `Bubo/Optimizer/Models/` — the optimizer's domain

A **derived** model layer the GA consumes. Types here are:

- **Computational** — `OptimizableEvent`, `ScheduleGene`, etc. Carry
  only the fields the fitness functions, constraints, and operators
  actually read.
- **`Sendable`-strict** — value types with no observation, no
  references back to UI state. Required because the GA fans work out
  across `Task`s and the island model needs deterministic input.
- **Optimizer-internal** — nothing outside `Bubo/Optimizer/` should
  import these directly. Application code that wants to drive the
  optimizer passes `CalendarEvent`/`BacklogTask` and lets
  `EventConversion` translate at the boundary.
- **Free to evolve** — adding a field to `OptimizableEvent` doesn't
  break persistence or the UI. That's the whole point of the
  separation.

Files: `OptimizerModels.swift` (the `OptimizableEvent` + friends),
`ScheduleTypes.swift` (`Horizon`, `Speed`, … shared across optimizer
+ intents), `EventConversion.swift` (the only bridge),
`TaskSignature.swift` (hash key for component-fitness caching).

## The bridge: `EventConversion`

`Bubo/Optimizer/Models/EventConversion.swift` is the **only** file
that knows about both worlds. It defines extensions on
`CalendarEvent` and `BacklogTask` that materialize their
`OptimizableEvent` projections.

Direction matters: conversion goes **app domain → optimizer domain**.
The optimizer returns its results as a separate type
(`Schedule`/`ScheduleGene`) which is then mapped *back* into
`CalendarEvent` mutations by `OptimizerService`. There is no
reverse `OptimizableEvent.toCalendarEvent()` — by design.

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

## Rules

- New computational fields the GA wants → `Optimizer/Models/`.
- New user-facing or persisted fields → `Bubo/Domain/`. Then extend
  `EventConversion` if the GA also needs to read it.
- Never `import` from `Optimizer/Models/` outside the
  `Bubo/Optimizer/` subtree. The composition root and application
  services consume the app domain only.
- Pomodoro is dual-citizen: `PomodoroDefaults` lives in
  `Bubo/Domain/` (user-tunable settings), `PomodoroConfig` lives in
  `Bubo/Optimizer/Models/` (per-event compiled settings the GA
  reads).
