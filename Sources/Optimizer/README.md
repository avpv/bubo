# Optimizer

A self-contained scheduling engine that lives as a peer of `Domain/`
rather than a sub-folder. It is **pure domain logic**: every source
file imports only `Foundation` (plus `os` for logging). No SwiftUI,
no AppKit, no EventKit, no SwiftData, and no references to
`Application/`- or `Infrastructure/`-layer services.

The peer placement is deliberate. The optimizer is large enough that
folding it into `Domain/Optimizer` would dwarf the rest of the domain
folder, and small enough that it doesn't need its own SwiftPM target
*yet* — but the boundary is now clean enough that lifting it into one
is a localized change (only `Package.swift` and `public` annotations).
Logically it is still Domain — Application talks to it through
`Application/Optimizer/OptimizerService`.

## Folder Map

| Folder | What lives there |
| --- | --- |
| `Orchestrator/` | `BuboOptimizer` — the top-level coordinator that runs a scheduling pass end-to-end |
| `Models/` | Plain value types the optimizer operates on (Task, Slot, Schedule, etc.) |
| `Anchors/` | Fixed points in time the schedule must respect (existing events, deadlines) |
| `Constraints/` | Hard rules a candidate schedule must satisfy |
| `Fitness/` | Soft scoring — `Objectives/` are the individual weights, `Fitness.swift` combines them |
| `GeneticAlgorithm/` | The GA search machinery. Subdivided: `Core/` (chromosome, population, config, random, slots), `Operators/` (selection, crossover, mutation, distance, symmetry-breaking), `Repair/` (CP / CPSAT / regret repair + CPSAT seed), `Adaptive/` (mutation/LNS bandits, tabu, LNS destroy), `IslandModel/` (island GA + migration + path relinking), `Engine/` (top-level GA, evolution hooks, plateau detector, QD archive, GNN warm-start, differentiable relaxation) |
| `Scenarios/` | Resulting candidate schedules surfaced to the UI |
| `Reoptimizer/` | Incremental rescheduling — react to a small change without redoing the whole pass |
| `Learning/` | Adaptive pieces with no service dependencies (`ActiveLearningSampler`, `CalendarEmbedding`, `ChanceConstrainedBuffers`, `DPOWeightLearner`). The accept/reject history learners (`IntentLearner`, `PreferenceLearner`) live in `Application/Learning/` because they talk to `CloudSyncService`. |
| `Training/` | Offline training entry points for the learning weights |

## Where Intents Live

`Intents/` (high-level user goals translated into optimizer requests)
**used to live here** but moved to `Application/Intents/` because the
compilers and rankers depend on `ReminderService`, `BacklogService`,
`EnergyCheckInService`, `PomodoroHistoryService`, and `OptimizerService`
itself — those are application-layer concerns, not optimizer concerns.
The optimizer consumes the compiled `OptimizationRequest` value type,
not the services that produced it.

## Boundary Rule

If a file under `Optimizer/` ever needs `import EventKit`,
`import SwiftUI`, or to reference any `*Service` type from
`Application/` or `Infrastructure/`, it's in the wrong layer. The
adapter belongs in `Application/Optimizer` (talks to services) or
`Infrastructure/` (talks to the platform). Optimizer code should
consume value types that the application layer prepared for it.
