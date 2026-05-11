# Fitness objectives

> **Kind:** concept
> **Sources:** Bubo/Optimizer/Fitness/, Bubo/Optimizer/Fitness/Objectives/, Bubo/Optimizer/Fitness/FitnessEvaluator.swift, Bubo/Optimizer/Constraints/Constraint.swift
> **Last ingest:** 2026-05-11
> **Related:** [`genetic-algorithm.md`](genetic-algorithm.md), [`../modules/optimizer.md`](../modules/optimizer.md), [`intents.md`](intents.md)

## What

The GA optimizes a schedule against many objectives in parallel. Each objective is a self-contained module under `Optimizer/Fitness/Objectives/`. `FitnessEvaluator.swift` aggregates them; NSGA-III (`NSGA3.swift`) drives many-objective selection.

## The 16 objectives

Verified by reading the file headers. `(global)` means no partitioning trait — full recompute every evaluation; `(day)` conforms to `DayPartitionedObjective` (delta evaluation rescores only dirty days); `(component)` conforms to `ComponentPartitionedObjective` (delta evaluation rescores only affected dependency chains).

| Objective | Trait | Weight | Scores |
|---|---|---:|---|
| `ConflictObjective` | day | 10.0 | Soft penalty for movable events overlapping fixed/other movable events. Complements the **hard** `NoOverlapConstraint` (`Constraints/Constraint.swift:38`). Per-day count-weighted arithmetic mean (not geometric) — avoids dilution from near-misses on fixed collisions |
| `MultiPersonObjective` | global | 5.0 | Availability of required participants during event time; partial overlap gets partial credit; 0.8 fallback when no availability data. Dropped events stay in denominator with score 0 |
| `DeadlineObjective` | day | 3.0 | Early-completion bonus + cramming penalty per deadline event. Per-day count-weighted mean approximation; delta-path fidelity loss is below GA noise |
| `BacklogOrderObjective` | global | 1.5 | Kendall-style inversion count of backlog tasks across all days. O(N log N) merge sort. Global because day-partitioning loses signal when tasks span days |
| `BreakObjective` | day | 1.2 | Penalty for long consecutive meetings + reward for lunch-time gaps + break adequacy ratios |
| `FocusBlockObjective` | day | 1.0 | Length and number of uninterrupted focus blocks. Longer continuous free time scores higher than fragmented. ~6× speedup from delta-eval on weekly plans |
| `TaskInclusionObjective` | global | 1.0 | Priority-weighted fraction of *droppable* tasks included. Priority is squared to sharpen tier gaps. Position boost capped at 1.1× (tiebreaker only) |
| `TaskPlacementObjective` | global | 1.0 | Composite (0.4 preferred hour band + 0.2–0.4 earliness gradient + 0.3 interruption avoidance + 0.1 priority alignment). Per-gene caches to avoid O(N²) lookups |
| `EnergyCurveObjective` | global | 0.9 | High-energy tasks at peak personal energy times. Simulates energy depletion during meetings + recovery during breaks. Personal 24-h curve when available, else Gaussian fallback on peak hours |
| `MeetingClusteringObjective` | day | 0.8 | Actively compresses movable meetings (cluster density 40% / focus yield from ≥60-min blocks 35% / fragmentation penalty 25%). `clusterGapThreshold` default 15 min. Distinct from FocusBlock: incentivizes clustering rather than passively scoring gaps |
| `PomodoroFitObjective` | global | 0.8 | Uninterrupted Pomodoro session fit + timing preference (peak hours) + post-session break adequacy (40/30/30). Dropped pomodoro stays in denominator with 0 |
| `WeekBalanceObjective` | global | 0.8 | Coefficient of variation of daily meeting load across working days; lower CV scores higher. Up to 10% penalty per minute exceeding `maxMeetingsPerDay × 60`. Exponential decay on CV |
| `ContextSwitchObjective` | day | 0.7 | Penalty for switches between project/category; reward for clustering same-context. Per-day exponential decay on switch count + cluster bonus |
| `BufferObjective` | day | 0.6 | Ratio of "well-buffered pairs" to all consecutive pairs per day. Heavier meetings require larger buffers. Days with <2 events score 1.0 |
| `DayCompactnessObjective` | day | 0.5 | `taskMinutes / spanMinutes` for movable tasks only. Rewards placing same-day tasks close together to leave contiguous free time at day edges. Intentionally context-agnostic |
| `PrecedenceObjective` | component | 0.5 | Gap size between prerequisite end and dependent start. ~1.0 for back-to-back, ~0.6 for ~1 working day, decays to 0 over horizon. Target gap default 8 h. **Soft** complement to the **hard** `TaskDependencyConstraint` (`Constraints/Constraint.swift:315`) |

To re-verify list: `ls Bubo/Optimizer/Fitness/Objectives/` (16 files); conformance: `grep -h ": .*Objective" Bubo/Optimizer/Fitness/Objectives/*.swift`.

## Soft / hard split

Two objectives **pair** with hard constraints:

- `ConflictObjective` ↔ `NoOverlapConstraint` (`Constraints/Constraint.swift:38`) — the constraint blocks gross overlaps; the objective shapes near-misses (5-min collision penalties).
- `PrecedenceObjective` ↔ `TaskDependencyConstraint` (`Constraints/Constraint.swift:315`) — the constraint enforces order; the objective shapes the *gap size* between predecessor and successor.

Both hard constraints are wired in `ConstraintEngine.swift:17`.

## Three partitioning traits

| Trait | Protocol declared at | When `FitnessEvaluator` can do delta-eval |
|---|---|---|
| (none) | — | Never — recompute on every chromosome |
| Day | `FitnessEvaluator.swift:143` | Rescore only days that contain mutated genes (or that used to) |
| Component | `FitnessEvaluator.swift:197` | Rescore only dependency chains containing mutated genes |

The classification table comment at `FitnessEvaluator.swift:320–334` lists which objectives conform but is **drifted**: as of this ingest it names `BreakPlacement, Buffer, FocusBlock, ContextSwitch, MeetingClustering` as Day-partitioned (5), but the actual file headers show 8 conformers (also `Conflict, DayCompactness, Deadline`). Treat the comment as historical context, the grep as source of truth.

Discovery is runtime via `objective as? DayPartitionedObjective` / `objective as? ComponentPartitionedObjective` (`FitnessEvaluator.swift:621`, `:730`) — not via an explicit list.

## Aggregation

Two paths:

- **Many-objective (default):** Pareto-rank via `NSGA3.swift`. Reference points are managed by `AdaptiveReferencePoints.swift`; objectives can be clustered by correlation in `ObjectiveClustering.swift`.
- **Lexicographic:** `LexicographicFitness.swift` for cases where the user pins a strict priority order.

## Caches

`FitnessCache.swift` (per-solution) and `ComponentFitnessCache.swift` (per-objective). Both sharded for parallel access.

## Approximation

`Surrogate.swift` is **RBF interpolation + kNN uncertainty proxy** — explicitly *not* a Gaussian Process (`Surrogate.swift:3–22`). RBF over a sliding window of recent real evaluations with Gaussian distance kernel; uncertainty is distance to the nearest training sample (cheap kNN-style local-roughness heuristic). Substantially cheaper than full GP (no kernel matrix inversion), behaves similarly on calendar fitness landscapes (smooth locally with islands of irregular structure). `MultiFidelityEvaluator.swift` routes cheap proxies for most candidates; the full evaluator only runs on promising ones. `DiffusionRefinement.swift` provides a refinement pass on near-elites.

## Drop semantics

When a chromosome drops a task, an inclusion-ratio exponent (`FitnessEvaluator.swift:340–350`) is applied **per objective** rather than to the scalar sum. Reason: NSGA-III ranks by Pareto domination on the raw objective vector; a multiplicative penalty on the scalar alone leaves the non-dominated sort free to pick drop-solutions whose structural axes look better. Squaring per-axis means a 1-of-4 drop caps every structural score at `0.75² = 0.5625×` of its raw value — no feasible structural upside can recover, so keep-solutions dominate drop-solutions on every axis.

## Weights

Objective weights come from three sources, in priority order:

1. Active `ScheduleIntent`s compiled by `IntentCompiler`.
2. Learned weights from `Optimizer/Learning/PreferenceLearner.swift` / `DPOWeightLearner.swift` based on accept/reject history.
3. Per-objective defaults listed in the table above.

See [`intents.md`](intents.md) for the intent path.
