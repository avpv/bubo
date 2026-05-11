# Fitness objectives

> **Kind:** concept
> **Sources:** Bubo/Optimizer/Fitness/, Bubo/Optimizer/Fitness/Objectives/
> **Last ingest:** 2026-05-11
> **Related:** [`genetic-algorithm.md`](genetic-algorithm.md), [`../modules/optimizer.md`](../modules/optimizer.md), [`intents.md`](intents.md)

## What

The GA optimizes a schedule against many objectives in parallel. Each objective is a self-contained module under `Optimizer/Fitness/Objectives/`. `FitnessEvaluator.swift` aggregates them; NSGA-III (`NSGA3.swift`) drives many-objective selection.

## The objectives

| Objective | Optimizes for |
|---|---|
| `ConflictObjective` | No overlapping commitments |
| `DeadlineObjective` | Tasks finish before their deadline |
| `PrecedenceObjective` | Tasks with declared dependencies stay ordered |
| `BufferObjective` | Inter-task buffers respected |
| `ContextSwitchObjective` | Minimise topic / context churn |
| `FocusBlockObjective` | Protect deep-work blocks |
| `BreakObjective` | Breaks land at low-energy moments |
| `PomodoroFitObjective` | Pomodoro work-break structure matches the active rhythm |
| `TaskInclusionObjective` | All backlog tasks get scheduled (penalise leftovers) |
| `TaskPlacementObjective` | Tasks land in preferred time bands |
| `BacklogOrderObjective` | User's manual backlog sort order is respected |
| `MeetingClusteringObjective` | Meetings cluster instead of fragmenting the day |
| `MultiPersonObjective` | Multi-attendee events align with the team |
| `EnergyCurveObjective` | Hard tasks land at peak energy hours |
| `DayCompactnessObjective` | Days are compact; long tails are avoided |
| `WeekBalanceObjective` | Load spread across the week |

Counts may drift — re-check `Optimizer/Fitness/Objectives/` on next ingest.

## Aggregation

`FitnessEvaluator` evaluates all enabled objectives and combines them. Two paths exist:

- **Many-objective (default):** Pareto-rank via `NSGA3.swift`. Reference points are managed by `AdaptiveReferencePoints.swift`; objectives can be clustered by correlation in `ObjectiveClustering.swift`.
- **Lexicographic:** `LexicographicFitness.swift` for cases where the user pins a strict priority order.

## Caches

`FitnessCache.swift` and `ComponentFitnessCache.swift` cache per-solution and per-objective values. The cache is sharded for parallel access.

## Approximation

`Surrogate.swift` (Gaussian-process style) and `MultiFidelityEvaluator.swift` let cheap proxies handle most candidates while the full evaluator only runs on promising ones. `DiffusionRefinement.swift` provides a refinement pass on near-elite solutions.

## Weights

Objective weights come from three sources, in priority order:

1. Active `ScheduleIntent`s compiled by `IntentCompiler`.
2. Learned weights from `Optimizer/Learning/PreferenceLearner.swift` / `DPOWeightLearner.swift` based on accept/reject history.
3. Defaults baked into each objective.

See [`intents.md`](intents.md) for the intent path.
