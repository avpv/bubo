# Constraints

> **Kind:** concept
> **Sources:** Bubo/Optimizer/Constraints/, Bubo/Optimizer/Constraints/Constraint.swift, Bubo/Optimizer/Constraints/ConstraintEngine.swift
> **Last ingest:** 2026-05-11
> **Related:** [`fitness-objectives.md`](fitness-objectives.md), [`genetic-algorithm.md`](genetic-algorithm.md), [`../modules/optimizer.md`](../modules/optimizer.md)

## Hard vs soft

Bubo enforces a small number of **hard** constraints (a schedule violating them is infeasible) and a much larger number of **soft** objectives (see [`fitness-objectives.md`](fitness-objectives.md)). Two pairs intentionally overlap so the GA gets both a feasibility wall and a shaping gradient:

| Hard constraint | Paired soft objective | Why both |
|---|---|---|
| `NoOverlapConstraint` (`Constraint.swift:38`) | `ConflictObjective` (weight 10.0) | Constraint blocks gross overlaps; objective penalises near-misses (5-min collisions) that constraint logic treats as feasible |
| `TaskDependencyConstraint` (`Constraint.swift:315`) | `PrecedenceObjective` (weight 0.5) | Constraint enforces order; objective shapes the *gap size* between predecessor and successor |

Hard constraints are wired in `ConstraintEngine.swift:17`.

## The engine

`ConstraintEngine` (`struct` at `Constraints/ConstraintEngine.swift:6`) evaluates every constraint against a chromosome and returns: total penalty + feasibility flag + a detailed violation breakdown. Used inside the GA's evaluation step and by `CPSATRepair` when fixing infeasible offspring.

## Conflict graph

`ScheduleConflictGraph` (`struct` at `ScheduleConflictGraph.swift:36`) is the indexed pre-processing of movable events:

- Weakly-connected components — groups of mutually conflicting/precedence-related events.
- Transitive precedence — full reachability of "must come after" relations.
- Per-day interval indices for fast overlap checks.

It is the input to `ScheduleConflictGraphSalsaCache` and the `ComponentPartitionedObjective` delta-evaluation path.

## Salsa-style caching

The optimizer uses a **dependency-tracking memoization database** at `QueryDB.swift` (286 lines). Header at `:1–37` calls it "the bare-bones version of what `salsa` (Rust, used by rust-analyzer) and `Adapton` provide".

### `QueryDB<Output: Sendable>` (declared at `QueryDB.swift:81`)

| Concept | Where | What |
|---|---|---|
| `struct QueryKey` | `:46` | `(domain, identifier)` pair — example domains: `"intent.dependencies"`, `"noEventsBefore.11"` |
| `class QueryTracker` | `:60` | Handed to query builders. `read(_:)` records a dependency (`OSAllocatedUnfairLock<Set<QueryKey>>`) |
| `setInput(_:)` | `:114` | Bumps a monotonic `UInt64` revision counter on the input. Wraps with `&+` |
| `query(_:_:)` | `:142` | Run a closure with a tracker. Cache entry stores `[QueryKey: UInt64]` revision snapshot |
| `query(_:using:_:)` | `:184` | Variant that propagates the inner query's dep set into a parent tracker — essential for **transitive invalidation** in recursive queries |
| `propagateDeps(of:to:)` | `:218` | On cache hit, copies stored deps into parent. Otherwise transitive inputs wouldn't invalidate the outer query |
| `invalidateAll()` | `:243` | Drops every cached query and resets every input revision to 0 |

### Invalidation rule

On lookup, each recorded input's revision is compared against the live revision. **Any** mismatch (or any input missing entirely) invalidates the entry and forces a rebuild.

### Concurrency

`OSAllocatedUnfairLock` guards every map access, but **builds run outside the lock** (`:148`). Two threads racing on a stale query may both rebuild; the second store wins; both return logically identical values.

### Scope (limitations explicit in the header at `:32–37`)

`QueryDB` supports primitive inputs and one-level queries. Nested queries that read other queries' outputs require explicit re-tracking via the `using:` variant. Future PRs could layer a query-of-queries dependency graph on top.

### Two long-lived caches built on `QueryDB`

`BuboOptimizer` (`BuboOptimizer.swift:125–144`) keeps two warm across runs:

| Cache | Decomposition |
|---|---|
| `IntentGraphSalsaCache` (`IntentGraphSalsaCache.swift:55`) | Per-intent compile, per-pair conflict, per-phase bucket, whole-graph build. A single intent chip edit invalidates only the queries that touched that intent |
| `ScheduleConflictGraphSalsaCache` (`ScheduleConflictGraphSalsaCache.swift:66`) | Per-event metadata, per-pair overlap, reachability, whole-graph. Whole-graph build still routes through `ScheduleConflictGraph.build` for its existing fast paths |

Older LRU variants (`IntentGraphCache`, `ScheduleConflictGraphCache` in `GraphQueryCache.swift:28`) are retained for tests that prefer simpler memoization semantics.

## Reachability

`ReachabilityBitset` (`struct` at `ReachabilityBitset.swift:27`) replaces `[String: Set<String>]` for transitive precedence queries — O(1) "does A reach B?" via word-level bitmask operations. Used inside the conflict graph and by `ComponentPartitionedObjective`'s delta path.

## Repair

`CPSATRepair` (in `GACore/`, `struct CPSATAssignment` at `CPSATRepair.swift:74`) is a CDCL-lite constraint solver with Luby restarts and VSIDS-like activity bumping. Two roles:

- Run after mutation/crossover to fix any infeasibility the random op introduced.
- Run as a construction seeder when the GA cold-starts.

## Concurrency

Caches are designed for parallel GA evaluation. `ShardedLRUCache` (`ShardedLRUCache.swift:33`) uses 8 shards each with its own `OSAllocatedUnfairLock` — concurrent lookups by different threads contend only when they hit the same shard, reducing lock contention compared to a single-mutex LRU.
