# Optimizer

A self-contained scheduling engine that lives as a peer of `Domain/`
rather than a sub-folder. It is **pure domain logic**: every source
file imports only `Foundation` (plus `os` for logging). No SwiftUI,
no AppKit, no EventKit, no SwiftData.

The peer placement is deliberate. The optimizer is large enough that
folding it into `Domain/Optimizer` would dwarf the rest of the domain
folder, and small enough that it doesn't need its own module yet.
Logically it is still Domain — Application talks to it through
`Application/Optimizer/OptimizerService`.

## Folder Map

| Folder | What lives there |
| --- | --- |
| `Orchestrator/` | `BuboOptimizer` — the top-level coordinator that runs a scheduling pass end-to-end |
| `Models/` | Plain value types the optimizer operates on (Task, Slot, Schedule, etc.) |
| `Anchors/` | Fixed points in time the schedule must respect (existing events, deadlines) |
| `Intents/` | High-level user goals translated into optimizer requests |
| `Constraints/` | Hard rules a candidate schedule must satisfy |
| `Fitness/` | Soft scoring — `Objectives/` are the individual weights, `Fitness.swift` combines them |
| `GeneticAlgorithm/` | The GA search machinery (selection, crossover, mutation) |
| `Scenarios/` | Resulting candidate schedules surfaced to the UI |
| `Reoptimizer/` | Incremental rescheduling — react to a small change without redoing the whole pass |
| `Learning/` | Adaptive weights based on the user's accept/reject history |
| `Training/` | Offline training entry points for the learning weights |

## Boundary Rule

If a file under `Optimizer/` ever needs `import EventKit` or
`import SwiftUI`, it's in the wrong layer. The adapter belongs in
`Application/Optimizer` (talks to services) or `Infrastructure/`
(talks to the platform). Optimizer code should consume value types
that the application layer prepared for it.
