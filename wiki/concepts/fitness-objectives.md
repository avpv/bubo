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
| `ConflictObjective` | day | 10.0 | Soft penalty for overlaps. **Score = `exp(-totalOverlapMinutes·0.05)·0.8 + exp(-nearMissMinutes·0.02)·0.2`** (80/20 split — `ConflictObjective.swift:135`). Per-day arithmetic mean avoids geometric-mean dilution. Complements the **hard** `NoOverlapConstraint` (`Constraints/Constraint.swift:38`) |
| `MultiPersonObjective` | global | 5.0 | Per-event availability score. **0.8 fallback only when no participant data exists**. Partial overlap scored as `min(1.0, overlapMinutes / eventMinutes) · 0.5` (`MultiPersonObjective.swift:60`). Dropped events stay in denominator with score 0 |
| `DeadlineObjective` | day | 3.0 | Early-completion bonus + **cramming penalty `Double(otherSameDay) · 0.05`** + priority bonus `earlyScore · priority · 0.2` (`DeadlineObjective.swift:144–147`). Per-day count-weighted mean approximation |
| `BacklogOrderObjective` | global | 1.5 | Kendall-style inversion count. Score = `1.0 - inversions / maxPairs`. O(N log N) merge sort. Global because day-partitioning loses signal when tasks span days |
| `BreakObjective` | day | 1.2 | **Weights: consecutive 0.4 / adequate-breaks 0.3 / lunch 0.3** (`BreakObjective.swift:104–147`). Lunch gap score = `min(1.0, lunchGap / (30 · 60))` |
| `FocusBlockObjective` | day | 1.0 | **Weights: longest-block 0.6 / fragmentation 0.2 / avg-block 0.2** (`FocusBlockObjective.swift:99–108`). Filters gaps `≥ 30 min` for block boundaries. ~6× speedup from delta-eval on weekly plans |
| `TaskInclusionObjective` | global | 1.0 | Priority-weighted fraction of droppable tasks included. Base weight `pow(priority + 0.1, 2)` (`TaskInclusionObjective.swift:51`). Position boost `1.0 + 0.1·earliness` capped at 1.1× (`:60`). Dropped droppables stay in denominator |
| `TaskPlacementObjective` | global | 1.0 | **Weights: preferred-hour 0.4 / earliness fallback 0.2 + energy 0.1 / interruption-avoidance 0.3** (`TaskPlacementObjective.swift:54–109`). Earliness gradient applies *only* when no `preferredHourRange`. Per-gene caches avoid O(N²) lookups |
| `EnergyCurveObjective` | global | 0.9 | High-energy tasks at peak energy. **Full-horizon eval, not day-partitioned.** Energy depletes per event: `energy -= event.energyCost · durationHours · decayRate` (`EnergyCurveObjective.swift:82`). Recovery: `0.15 · log2(1.0 + gapHours · 4.0)` (`:54`). Personal 24-h curve if available, else Gaussian fallback |
| `MeetingClusteringObjective` | day | 0.8 | **Five sub-scores: density 0.30 / focus 0.25 / fragmentation 0.15 / window-align 0.15 / cluster-size 0.15** (`MeetingClusteringObjective.swift:104–108`) — **not** the 40/35/25 the wiki used to claim. `clusterGapThreshold` default 15 min |
| `PomodoroFitObjective` | global | 0.8 | **Weights: interruptions 0.4 / timing 0.3 / post-session break 0.3** (`PomodoroFitObjective.swift:54`). Long break only applies after >1 round (`:76–82`). Dropped Pomodoro stays in denominator with 0 |
| `WeekBalanceObjective` | global | 0.8 | CV-based balance scoring with `exp(-cv)` (`WeekBalanceObjective.swift:58`). **Overload penalty `(dayMinutes - maxMinutes) / maxMinutes · 0.1` per violating day** (`:62–64`) — not "10% per minute" as the wiki used to claim |
| `ContextSwitchObjective` | day | 0.7 | **Fuzzy prefix matching** on shared path segments — `switchSeverity()` returns fraction of differing segments (`ContextSwitchObjective.swift:75`). Cluster bonus 0.025–0.1 for runs of 3+ same-context events (`:108–110`) |
| `BufferObjective` | day | 0.6 | Ratio of well-buffered pairs to all consecutive pairs per day. **Heavy threshold `energyCost > 0.7` uses `preferences.heavyMeetingBufferMinutes`**, otherwise `preferences.defaultBufferMinutes` (`BufferObjective.swift:82–84`). Days with <2 events score 1.0 |
| `DayCompactnessObjective` | day | 0.5 | `taskMinutes / spanMinutes` for movable tasks only — **fixed events explicitly excluded** (`DayCompactnessObjective.swift:59–61`). Ratio clamped to `[0, 1]` (`:85`). Days with <2 movable events score 1.0 |
| `PrecedenceObjective` | component | 0.6 | Gap decay via **`exp(-ratio)`** where `ratio = gap / targetGap` (`PrecedenceObjective.swift:78–86`). Target gap default 8 h. Dropped/unfeasible pairs contribute 0. **Hard-coded weight at `FitnessEvaluator.swift:311`** (not from `OptimizerPreferences`). Soft complement to the **hard** `TaskDependencyConstraint` (`Constraints/Constraint.swift:315`) |

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
3. Per-objective defaults listed in the table above. Default values come from `OptimizerPreferences.init` (`Optimizer/Models/OptimizerModels.swift:583–597`) except `PrecedenceObjective` which is fixed at `0.6` in `FitnessEvaluator.swift:311`.

See [`intents.md`](intents.md) for the intent path.
