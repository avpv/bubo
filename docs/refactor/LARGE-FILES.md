# Large-file decomposition — remaining work

Files >700 LoC are split into two buckets based on shape:

## Bucket A — done in current branch (mechanical)

Each split was a pure `cat | sed` of consecutive lines into sibling
files, no code change. Each new file gets matching `import` headers.

| Original | Before | After |
|---|---|---|
| `Sources/BuboOptimizer/Fitness/FitnessEvaluator.swift` | 961 | 712 + `FitnessEvalTelemetry.swift` (133) + `FitnessObjective.swift` (120) |
| `Sources/BuboOptimizer/GeneticAlgorithm/Adaptive/MutationBandit.swift` | 693 | 427 + `Adaptive/LNSBandit.swift` (268) |
| `Sources/BuboOptimizer/GeneticAlgorithm/Engine/GNNWarmStart.swift` | 666 | 367 + `Engine/GNNWarmStartTrainer.swift` (301) |
| `Sources/BuboOptimizer/GeneticAlgorithm/Repair/CPSATRepair.swift` | 745 | 622 + `Repair/CPSATAtoms.swift` (125) |
| `Sources/BuboOptimizer/Models/OptimizerModels.swift` | 676 | split into `ScheduleGene.swift` (180) + `OptimizerContext.swift` (201) + `OptimizerPreferences.swift` (185) + `OptimizerResult.swift` (119); original deleted |
| `Bubo/Application/Intents/ScheduleIntent.swift` | 763 | 302 + `ScheduleIntent+Conditions.swift` (262) + `OptimizationRequest.swift` (207) |

No symbol moved targets, no access modifiers changed, no Package.swift
update needed (each new sibling file is included automatically by the
target's path-based file discovery).

## Bucket B — single-type giants (need real refactor)

These files are a single SwiftUI `View struct` or one large `class` /
`struct` with dozens of `private` methods. Splitting them is not a
pure file move — it requires moving private methods into
`extension Type { ... }` blocks in sibling files, which in turn
requires widening `private` access to `internal` (Swift `extension` in
a sibling file cannot access `private` members of the original type;
`fileprivate` is per-file).

Recommended split pattern for SwiftUI giants:
1. Identify "section MARK" boundaries inside the View. Each MARK
   usually clusters 3-10 helper computed properties / methods.
2. Move that group into `extension TheView { ... }` in a new file
   `TheView+SectionName.swift`.
3. Change the moved methods' access from `private` to `internal`
   (drop the modifier — `internal` is the default).

Pattern for single-class giants (e.g. `AppleRemindersService`,
`SubgraphRegistry`):
- Same idea — split by feature into `extension Class { ... }` siblings.
- For `@MainActor` classes, the sibling extension must declare
  `@MainActor extension Class { ... }` or the conformance carries
  through if the type itself is `@MainActor`.

| File | Lines | Suggested split |
|---|---|---|
| `Bubo/Presentation/Views/Backlog/BacklogFullscreenView.swift` | 954 | `+Suggestion.swift`, `+CapacityForecast.swift`, `+Filters.swift` |
| `Bubo/Presentation/Views/Components/Slot/SlotPickerPopover.swift` | 951 | `+Layout.swift`, `+Interaction.swift` |
| `Bubo/Presentation/Views/Components/Background/WallpaperBackgroundLayer.swift` | 932 | `+Animation.swift`, `+Layers.swift` |
| ~~`Sources/BuboOptimizer/GeneticAlgorithm/Repair/Chromosome+CPSATSeed.swift`~~ | ~~822~~ | **Done 2026-05-13.** 822 → 326 (`Chromosome+CPSATSeed.swift`, cpSeeded only) + 496 (`Chromosome+SlotSearch.swift`, findFirstFreeSlot/findLastFreeSlot/enumerateFeasibleSlots/OccupiedInterval). All four were already `public static` — no visibility change needed. |
| `Bubo/Presentation/Views/Event/EditTaskView.swift` | 814 | `+Pomodoro.swift`, `+Recurrence.swift`, `+Reminders.swift` |
| `Bubo/Presentation/Views/CommandPalette/CommandPalette.swift` | 788 | `+Search.swift`, `+Results.swift`, `+Keyboard.swift` |
| `Sources/BuboOptimizer/Orchestrator/BuboOptimizer.swift` | 770 | already has several `BuboOptimizer+X.swift` siblings; merge orphan helpers into them or add `+Generations.swift` |
| `Bubo/Presentation/Views/Components/Backlog/BacklogTaskRow.swift` | 732 | `+Header.swift`, `+Body.swift`, `+Footer.swift` |
| `Bubo/Application/Intents/Graph/IntentGraph.swift` | 726 | `+Construction.swift`, `+Traversal.swift` (already has `+Phase.swift`, `+Rules.swift`) |
| `Bubo/Presentation/Views/Components/Event/EventRowView.swift` | 722 | `+Pomodoro.swift`, `+Drag.swift`, `+Pin.swift` |
| `Bubo/Presentation/Views/Timer/TimerScreenView.swift` | 695 | `+Controls.swift`, `+Layout.swift` |
| `Bubo/Presentation/Views/Components/Backlog/SmartActions.swift` | 693 | `+Cards.swift`, `+Ranking.swift` |
| `Bubo/Infrastructure/Apple/AppleRemindersService.swift` | 676 | `+Sync.swift`, `+Write.swift`, `+Convert.swift` |

## Validation per split

Each split, regardless of bucket, must pass:
1. `swift build` — every type still resolves.
2. `swift test` — public behaviour unchanged.
3. `grep -rn 'TheTypeOrFunc' Bubo Sources Tests` — no orphaned callers
   pointing at the old single file.

For Bucket B, additionally:
- Confirm no `private` member is referenced from outside its
  originating file. Visual diff helps — every moved method should
  appear as a clean `extension TheType { existing-method }` paste.
