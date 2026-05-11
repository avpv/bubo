# Fitness objectives

> **Kind:** concept
> **Sources:** Bubo/Optimizer/Fitness/, Bubo/Optimizer/Fitness/Objectives/
> **Last ingest:** 2026-05-11
> **Related:** [`genetic-algorithm.md`](genetic-algorithm.md), [`../modules/optimizer.md`](../modules/optimizer.md), [`intents.md`](intents.md)

## What

The GA optimizes a schedule against many objectives in parallel. Each objective is a self-contained module under `Optimizer/Fitness/Objectives/`. `FitnessEvaluator.swift` aggregates them; NSGA-III (`NSGA3.swift`) drives many-objective selection.

## The objectives

Exactly **16** files in `Optimizer/Fitness/Objectives/` as of last ingest. To re-check: `ls Bubo/Optimizer/Fitness/Objectives/ | wc -l`.

| Objective | Optimizes for |
|---|---|
| `BacklogOrderObjective` | User's manual backlog sort order is respected |
| `BreakObjective` | Breaks land at low-energy moments |
| `BufferObjective` | Inter-task buffers respected |
| `ConflictObjective` | No overlapping commitments |
| `ContextSwitchObjective` | Minimise topic / context churn |
| `DayCompactnessObjective` | Days are compact; long tails are avoided |
| `DeadlineObjective` | Tasks finish before their deadline |
| `EnergyCurveObjective` | Hard tasks land at peak energy hours |
| `FocusBlockObjective` | Protect deep-work blocks |
| `MeetingClusteringObjective` | Meetings cluster instead of fragmenting the day |
| `MultiPersonObjective` | Multi-attendee events align with the team |
| `PomodoroFitObjective` | Pomodoro work-break structure matches the active rhythm |
| `PrecedenceObjective` | Tasks with declared dependencies stay ordered |
| `TaskInclusionObjective` | All backlog tasks get scheduled (penalise leftovers) |
| `TaskPlacementObjective` | Tasks land in preferred time bands |
| `WeekBalanceObjective` | Load spread across the week |

## Aggregation

`FitnessEvaluator` evaluates all enabled objectives and combines them. Two paths exist:

- **Many-objective (default):** Pareto-rank via `NSGA3.swift`. Reference points are managed by `AdaptiveReferencePoints.swift`; objectives can be clustered by correlation in `ObjectiveClustering.swift`.
- **Lexicographic:** `LexicographicFitness.swift` for cases where the user pins a strict priority order.

## Delta evaluation: `DayPartitionedObjective`

Defined at `Optimizer/Fitness/FitnessEvaluator.swift:143`. Objectives that conform implement `evaluatePerDay(...) -> [Date: Double]` keyed by `calendar.startOfDay(for:)`. When the GA mutates a chromosome, `FitnessEvaluator` rescores only days containing mutated genes (or that used to). Currently conforming (per comment at `FitnessEvaluator.swift:324`): `BreakObjective`, `BufferObjective`, and others — the list is maintained as a literal classification table in the evaluator rather than via `as?` casts (per a comment there, the cast-based form would silently rot when new objectives opt in). A parallel `Graph`-partitioned trait composes orthogonally — an objective can conform to both and the evaluator picks the cheaper decomposition (`FitnessEvaluator.swift:191`).

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
