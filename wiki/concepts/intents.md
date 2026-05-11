# Intents

> **Kind:** concept
> **Sources:** Bubo/Optimizer/Intents/, Bubo/Optimizer/Learning/IntentLearner.swift, Bubo/Views/CommandPalette.swift
> **Last ingest:** 2026-05-11
> **Related:** [`agent-service.md`](agent-service.md), [`fitness-objectives.md`](fitness-objectives.md), [`genetic-algorithm.md`](genetic-algorithm.md)

## What

An **intent** is a declarative statement about how to schedule — "block 2–5pm for deep work", "prioritise project X this week", "defer Y to Friday". Intents are the user's lever for steering the optimizer without micromanaging slot assignments.

## Pipeline

`IntentCompiler` is more than a translator — its `execute(_:defaultWorkingHours:)` runs an eight-stage pipeline and returns the optimizer's `OptimizationResult` directly. Stages, from the header comment at `Bubo/Optimizer/Intents/IntentCompiler.swift:8`:

1. Expand subgraphs and apply variables
2. Build DAG from expanded intents (auto-resolve deps)
3. Validate ports (type-check connections)
4. Topologically sort by phase (`trigger` → `source` → … → `output`)
5. Evaluate conditions at runtime
6. Apply transforms to events
7. Compile into `OptimizerContext` → run GA
8. Process output nodes (`autoApply`, `chain`, `notify`)

So intents are not a flat list of constraints; they form a typed DAG that compiles to an `OptimizerContext` *and* drives post-GA actions. The compiler depends on `BuboOptimizer`, `ReminderService`, `BacklogService`, optionally `SubgraphRegistry`, `EnergyCheckInService`, `PomodoroHistoryService` (`IntentCompiler.swift:23–32`). It tags every run with an 8-char `requestId` for log correlation (`IntentCompiler.swift:42`).

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

## Files

| File | Role |
|---|---|
| `ScheduleIntent.swift` | The intent DSL data types (`ScheduleIntent`, `OptimizationRequest`) |
| `IntentCompiler.swift` | 8-stage graph executor: expand → DAG → port-check → topo-sort → conditions → transforms → compile to `OptimizerContext` + run GA → output nodes |
| `IntentGraph.swift`, `IntentGraphAdvanced.swift` | Dependency DAG between intents |
| `IntentConflictDetector.swift` | Flags contradictions before they reach the GA |
| `IntentLearner.swift` (in `Optimizer/Learning/`) | Updates intent weights based on accept/reject |
| `IntentPresets.swift` | Common templates surfaced in UI |
| `LLMIntentBridge.swift` | Natural language → `ScheduleIntent` via Claude tool_use |
| `SuggestionEngine.swift` | Generates suggested intents from context |
| `QuickActionRanker.swift` | Ranks contextual quick actions |
| `TriggerEngine.swift` | Event-driven re-optimization triggers |
| `PomodoroConfigResolver.swift` | Picks the right Pomodoro rhythm for the current intent context |
| `BacklogTaskCohesion.swift` | Clusters tasks by colour/context for intent generation |

## Conflicts

`IntentConflictDetector` runs at compile-time before the GA. If two active intents contradict (e.g. "block 2–5pm" + "schedule X at 3pm where X has high deadline pressure"), it surfaces the conflict to the user instead of producing a confusing optimization result.

## Learning loop

`IntentLearner` and `PreferenceLearner` together adjust both intent priorities and objective weights based on which scenarios the user accepts. The DPO-style update is in `Optimizer/Learning/DPOWeightLearner.swift`.

## NL bridge

`LLMIntentBridge.swift` is the in-app side; the actual LLM call goes through `AgentService` — see [`agent-service.md`](agent-service.md).
