# Module: Tests

> **Kind:** module
> **Sources:** Tests/OptimizerTests/, Package.swift
> **Last ingest:** 2026-05-11
> **Related:** [`optimizer.md`](optimizer.md), [`services.md`](services.md)

## What is covered

`Tests/OptimizerTests/` covers the optimizer surface:

- **GA core:** selection, crossover, mutation, plateau detection, RNG determinism
- **Constraints:** conflict graph, reachability, cache correctness
- **Fitness:** surrogate behaviour, multi-fidelity evaluation, NSGA-III selection
- **Intents:** compilation from `ScheduleIntent` to constraints/weights, conflict detection
- **Objectives:** precedence, task placement, Pomodoro fit
- **Pomodoro:** rhythm phase generation
- **Backlog:** carry-over behaviour
- **Suggestions:** quick-action ranker

## What is NOT covered

- UI views, SwiftUI flows
- EventKit integration end-to-end (mocked via `FakeCalendarEventSource`)
- CloudKit sync
- AgentService / Claude API (manual)
- The proxy (`proxy/`)

## How to run

`swift test` from the repo root. The SPM manifest is `Package.swift`. The test target depends on the `Bubo` target.

## Fixtures

Most tests construct in-memory backlog tasks and synthetic calendar events. Fakes:

- `FakeCalendarEventSource` / `FakeRemindersEventSource` in `Services/Apple/`
- In-memory store fakes (paired with each protocol in `Services/Persistence/`)
