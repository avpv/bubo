# Intents

> **Kind:** concept
> **Sources:** Bubo/Optimizer/Intents/, Bubo/Optimizer/Learning/IntentLearner.swift, Bubo/Presentation/Views/CommandPalette.swift
> **Last ingest:** 2026-05-11 (rev: post-restructure)
> **Related:** [`agent-service.md`](agent-service.md), [`fitness-objectives.md`](fitness-objectives.md), [`genetic-algorithm.md`](genetic-algorithm.md)

## What

An **intent** is a declarative statement about how to schedule — "block 2–5pm for deep work", "prioritise project X this week", "defer Y to Friday". Intents are the user's lever for steering the optimizer without micromanaging slot assignments.

## Pipeline

`IntentCompiler` is more than a translator — its `execute(_:defaultWorkingHours:)` (`IntentCompiler.swift:35`) runs an eight-stage pipeline and returns the optimizer's `OptimizationResult` directly. Stages, from the header comment at `Bubo/Optimizer/Intents/IntentCompiler.swift:11–19`:

1. Expand subgraphs and apply variables
2. Build DAG from expanded intents (auto-resolve deps)
3. Validate ports (type-check connections)
4. Topologically sort by phase (`trigger` → `source` → … → `output`)
5. Evaluate conditions at runtime
6. Apply transforms to events
7. Compile into `OptimizerContext` → run GA
8. Process output nodes (`autoApply`, `chain`, `notify`)

So intents are not a flat list of constraints; they form a typed DAG that compiles to an `OptimizerContext` *and* drives post-GA actions. The compiler depends on `BuboOptimizer`, `ReminderService`, `BacklogService`, optionally `SubgraphRegistry`, `EnergyCheckInService`, `PomodoroHistoryService` (`IntentCompiler.swift:23–31`). It tags every run with an 8-char hex `requestId` for log correlation (`IntentCompiler.swift:43`).

```
NL prompt (CommandPalette)
   ↓ LLMIntentBridge (Claude tool_use)
[ScheduleIntent]                          (ScheduleIntent.swift)
   ↓ IntentCompiler.execute               (IntentCompiler.swift, 8-stage pipeline above)
OptimizationResult ← BuboOptimizer GA
   ↓ output nodes (autoApply / chain / notify)
   ↓ user accept/reject
Feedback                                  (Learning/IntentLearner.swift)
```

## Historical context

The intent system **replaces** an earlier "recipe" system (`ScheduleIntent.swift:11`, `IntentPresets.swift:8`). The `LLMIntentBridge` header is "simpler than `LLMRecipeBridge`". Grep `Recipe` if you need the migration history.

## Files

| File | Type+line | Role |
|---|---|---|
| `ScheduleIntent.swift` | `indirect enum ScheduleIntent` (`:11`) | The intent DSL — atomic, composable cases. Replaces `ScheduleRecipe` |
| `IntentCompiler.swift` + 4 siblings | `struct IntentCompiler` (`:21`, `@MainActor` at `:20`) | 8-stage graph executor: expand subgraphs → build DAG → port-type-check → topo-sort by phase → evaluate conditions → apply transforms → compile to `OptimizerContext` + run GA → process output nodes (`autoApply`/`chain`/`notify`). The 1519-line monolith was split into `IntentCompiler.swift` (entry point `execute(...)` + capacity resolutions), `IntentCompiler+Apply.swift` (`ResolvedConfig` IR + per-intent application + condition eval + auto-pomodoro resolver), `IntentCompiler+EventCollection.swift` (synthetic/local/backlog event materialisation + source filters + transforms), `IntentCompiler+Preferences.swift` (config → `OptimizerPreferences` mapping), `IntentCompiler+Horizon.swift` (horizon resolution + pre-flight capacity check + backlog cap + snapshot builder). Each was originally a `private extension` block; visibility relaxed to plain `extension` for cross-file access. |
| `IntentGraph.swift` + 2 siblings | `struct IntentGraph` (`:12`) | DAG with typed edges. Dependency resolution, phase ordering, conflict detection, conditional logic. Static rules table (`phase(for:)`, `dependencies(for:)`, `suggestions(for:)`, `conflictReason(_:_:)`, `allKnownIntents`) lives in `IntentGraph+Rules.swift`; `Phase.displayName` localised labels in `IntentGraph+Phase.swift`. |
| `IntentGraphAdvanced.swift` | `struct Subgraph` (`:16`) | Named reusable group of intents that acts as a single node. Subgraphs nest and expand recursively |
| `IntentConflictDetector.swift` | `enum IntentConflictDetector` (`:12`) | Three severity levels: **hard conflicts**, warnings, info. Shown in the intent composer **before running** |
| `IntentLearner.swift` (in `Optimizer/Learning/`) | `class IntentLearner` (`:16`) | Updates intent weights based on accept/reject. Tracks co-occurrence, frequency, temporal patterns |
| `IntentPresets.swift` | `struct IntentPresets` (`:8`) | Named optimization presets — replaces the old recipe catalog |
| `LLMIntentBridge.swift` | `struct LLMIntentBridge` (`:15`) | Parses LLM-generated JSON intents and executes via `IntentCompiler` |
| `SuggestionEngine.swift` | `final class SuggestionEngine` (`:27`, `@MainActor @Observable`) | Composes smart optimization requests from context. Additive composition of `Signal`s and `ContextLayer`s with cardinality conflict resolution and attribution mapping |
| `QuickActionRanker.swift` | `struct QuickActionRanker` (`:24`, `@MainActor`) | Ranks quick actions using a Hacker-News-inspired scoring algorithm. Context signals boost relevant actions; usage history makes frequently-accepted actions rise |
| `TriggerEngine.swift` | `final class TriggerEngine` (`:17`, `@MainActor @Observable`) | Executes optimization requests based on triggers. **Scheduled** (`.daily`, `.weekly`) and **reactive** (`.onEventDeleted`, `.onNewEvent`, `.onCalendarSync`) sourced from `SubgraphRegistry` |
| `PomodoroConfigResolver.swift` | `struct PomodoroResolverTuning` (`:11`) | Centralises every magic number used by the resolver. Inspectable, unit-testable, overridable. Named minute-valued fields with justification |
| `BacklogTaskCohesion.swift` | `enum BacklogTaskCohesion` (`:12`) | Similarity policy for grouping backlog tasks inside a single `.focusBurst` session. Reusable wherever the optimizer needs a "these belong together" signal |

## Conflicts

`IntentConflictDetector` runs at compile-time before the GA. If two active intents contradict (e.g. "block 2–5pm" + "schedule X at 3pm where X has high deadline pressure"), it surfaces the conflict to the user instead of producing a confusing optimization result.

## Learning loop

`IntentLearner` and `PreferenceLearner` together adjust both intent priorities and objective weights based on which scenarios the user accepts. The DPO-style update is in `Optimizer/Learning/DPOWeightLearner.swift`.

## NL bridge

`LLMIntentBridge.swift` is the in-app side; the actual LLM call goes through `AgentService` (a DeepSeek client) — see [`agent-service.md`](agent-service.md).
