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
| `TaskDependencyConstraint` (`Constraint.swift:315`) | `PrecedenceObjective` (weight 0.6) | Constraint enforces order; objective shapes the *gap size* between predecessor and successor |

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

### `QueryDB<Output: Sendable>` (declared at `QueryDB.swift:78`)

| Concept | Where | What |
|---|---|---|
| `struct QueryKey` | `:41` | `(domain, identifier)` pair — example domains: `"intent.dependencies"`, `"noEventsBefore.11"` |
| `final class QueryTracker` | `:54` | Handed to query builders. `read(_:)` records a dependency (`OSAllocatedUnfairLock<Set<QueryKey>>`) |
| `setInput(_:)` | `:116` | Bumps a monotonic `UInt64` revision counter on the input. Wraps with `&+` (`:119`) |
| `query(_:_:)` | `:149` | Run a closure with a tracker. Cache entry stores `[QueryKey: UInt64]` revision snapshot |
| `query(_:using:_:)` | `:189` | Variant that propagates the inner query's dep set into a parent tracker — essential for **transitive invalidation** in recursive queries |
| `propagateDeps(of:to:)` | `:230` | On cache hit, copies stored deps into parent. Otherwise transitive inputs wouldn't invalidate the outer query |
| `invalidateAll()` | `:247` | Drops every cached query and resets every input revision to 0 |

### Invalidation rule

On lookup, each recorded input's revision is compared against the live revision. **Any** mismatch (or any input missing entirely) invalidates the entry and forces a rebuild.

### Concurrency

`OSAllocatedUnfairLock` guards every map access, but **builds run outside the lock** (`:146`). Two threads racing on a stale query may both rebuild; the second store wins; both return logically identical values.

### Scope (limitations explicit in the header at `:32–37`)

`QueryDB` supports primitive inputs and one-level queries. Nested queries that read other queries' outputs require explicit re-tracking via the `using:` variant. Future PRs could layer a query-of-queries dependency graph on top.

### Two long-lived caches built on `QueryDB`

`BuboOptimizer` (`BuboOptimizer.swift:125–144`) keeps two warm across runs. Both have **four separate `QueryDB`s** internally — one per output family — because `QueryDB<Output>` is single-output by design (`IntentGraphSalsaCache.swift:62`).

#### `IntentGraphSalsaCache` (`IntentGraphSalsaCache.swift:55`)

Four `QueryDB`s and the cached value types:

| DB | Output type | Dep set |
|---|---|---|
| `compileDB` | `IntentCompileEntry` (`:37`) — `(intent, nodeId, phase, dependencies, suggestions)` | `{input(intent)}` only — pure function of the intent. A chip edit on intent X invalidates only X's compile entry |
| `conflictDB` | `IntentConflictDecision` (`:50`) — `reason: String?` + `hasConflict` | `{input(a), input(b)}` for one unordered pair. **Headline win:** a chip edit on X invalidates at most N pair entries (the ones involving X); the other N·(N–1)/2 − N stay cached |
| `phaseDB` | `[IntentCompileEntry]` | Union of phase members' input keys |
| `graphDB` | `IntentGraph` | Whole-graph entries bounded by an LRU |

Whole-graph LRU cap: `wholeGraphCapacity: Int = 16` default (`:89`/`:91`). Per-intent / per-pair / per-phase entries are **not** capped — bounded by intent diversity (≤ hundreds in practice). Telemetry surfaces: `cachedGraphCount`, `cachedConflictPairCount`, `cachedCompileCount`.

`IntentGraph.build` is invoked through a conflict oracle that routes pair checks through `conflictDB` — so the build's pairwise sweep hits the cache instead of re-running `conflictReason` switches.

#### `ScheduleConflictGraphSalsaCache` (`ScheduleConflictGraphSalsaCache.swift:66`)

Mirrors the intent cache structure but with a deliberately narrower win surface — the file header (`:1–43`) is honest about scope:

| DB | Output type |
|---|---|
| `eventMetadataDB` | `ConflictEventMetadata` (`:47`) — `(id, dependsOn, participants, preferredHourLower, preferredHourUpper)` |
| `pairOverlapDB` | `ConflictOverlapDecision` (`:56`) — `(shareParticipant, hourRangesOverlap)` |
| `reachabilityDB` | `Set<String>` — transitive dependents of a source |
| `graphDB` | `ScheduleConflictGraph` |

**What Salsa actually gives here** (not "speeds up everything"):

- LRU-bounded whole-graph entries — same as the old hash cache, no regression.
- Per-event metadata + per-pair overlap caching for cross-context reuse (scenario passes sharing events).
- Per-pair invalidation tracking — changing one event's fields invalidates only the O(N) pair entries involving it, the other O(N²) stay cached.

**What Salsa does NOT give here:** build-time speedup on a cold first call. `ScheduleConflictGraph.build` already bypasses O(N²) via participant-index and sort+sweep optimizations, and routing pair checks through the Salsa oracle would *disable* that fast path — a net regression at current scales.

`registerInputs(for:)` (`ScheduleConflictGraphSalsaCache.swift:401`) tracks **per-event structural fingerprints** so only changed events bump revision. Unchanged events keep their cached per-event / per-pair / reachability entries valid across calls.

Reachability oracle (used by `ScheduleConflictGraph.build`) reads every movable-event input via the tracker — deliberate over-invalidation matching the monolithic DFS behaviour. This is deliberate over-invalidation: a reachability entry rebuilds whenever any event changes shape, matching the monolithic DFS's behaviour. The per-source cache still wins on same-shape re-evaluation (what-if scenarios, objective tweaks).

Logger subsystem `com.avpv.Bubo`, category `Optimizer/ConflictGraph`. Emits `conflict_graph_built` on miss with: rid, events count, components, conflict_edges, precedence_edges, density, build_ms.

#### Older LRU variants

`IntentGraphCache`, `ScheduleConflictGraphCache` in `GraphQueryCache.swift:28` — retained for tests that prefer simpler hash-keyed memoization without Salsa's dep-tracking overhead.

## Reachability

`ReachabilityBitset` (`struct` at `ReachabilityBitset.swift:27`) replaces `[String: Set<String>]` for transitive precedence queries — O(1) "does A reach B?" via word-level bitmask operations. Used inside the conflict graph and by `ComponentPartitionedObjective`'s delta path.

## Repair

`CPSATRepair` (in `GACore/`, `struct CPSATAssignment` at `CPSATRepair.swift:74`) is a CDCL-lite constraint solver with Luby restarts and VSIDS-like activity bumping. Two roles:

- Run after mutation/crossover to fix any infeasibility the random op introduced.
- Run as a construction seeder when the GA cold-starts.

## Concurrency

Caches are designed for parallel GA evaluation. `ShardedLRUCache` (`ShardedLRUCache.swift:33`) uses 8 shards each with its own `OSAllocatedUnfairLock` — concurrent lookups by different threads contend only when they hit the same shard, reducing lock contention compared to a single-mutex LRU.
