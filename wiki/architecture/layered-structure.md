# Layered structure

> **Kind:** architecture
> **Sources:** Package.swift, Bubo/Composition/, Sources/BuboDomain/, Sources/BuboDomain/Reminders/README.md, Bubo/Application/, Bubo/Application/Reminders/ReminderService.swift, Bubo/Application/Reminders/RemindersSyncService+Writeback.swift, Bubo/Application/Optimizer/OptimizerService+Settings.swift, Bubo/Infrastructure/, Bubo/Presentation/, Sources/BuboOptimizer/, Sources/BuboOptimizer/README.md
> **Last ingest:** 2026-05-13 (rev: PreferenceLearner core moved back to BuboOptimizer/Learning/; cloud-sync bridge extension remains in Bubo/Application/Learning/)
> **Related:** [`overview.md`](overview.md), [`domain-boundaries.md`](domain-boundaries.md), [`../modules/services.md`](../modules/services.md), [`../modules/models.md`](../modules/models.md), [`../modules/optimizer.md`](../modules/optimizer.md)

## Three SwiftPM targets

```
Package.swift declares three targets:

  BuboDomain ──┐
               │
               ├── BuboOptimizer ──┐
               │                    │
               ├────────────────────┴── Bubo (executable)
               │
               └── BuboTests @testable-imports all three

BuboDomain    (Sources/BuboDomain/)    — no dependencies. Pure value types.
BuboOptimizer (Sources/BuboOptimizer/) — depends on BuboDomain.
Bubo          (Bubo/, .executable)     — depends on BuboDomain + BuboOptimizer.
```

The split lifts the previous folder-only layering into module-level enforcement: `BuboOptimizer` cannot accidentally `import BuboServices` because Composition/Application/Presentation/Infrastructure all live inside the `Bubo` executable target, which sits *above* it in the graph. Similarly, `BuboDomain` cannot reach into anything else.

The split landed on 2026-05-12. Three preconditions were required:

1. Move Phase 1 services out of Optimizer/ (Intents/, IntentLearner, PreferenceLearner — they touched `CloudSyncService` and other Application types).
2. Break the Domain↔Optimizer cycle by moving `Period`, `PomodoroConfig`, `OptimizableEvent` from `Optimizer/Models/` to `Domain/`. They had always been domain concepts; the placement under Optimizer was historical. The move closed the cycle Optimizer-Models → Domain-uses-them ↔ Domain-types → Optimizer-uses-them.
3. Move `BacklogLogic.proposedSlotsFromShadow(_:)` out of Domain (it took a `ScheduleScenario` parameter, an Optimizer type) into an extension under `Application/Backlog/`. The call site is unchanged.

## Top-level layout

```
Sources/
├── BuboDomain/      # Target 1 — Pure value types, no deps
│   ├── Backlog/             # BacklogTask, BacklogLogic
│   ├── Calendar/            # CalendarEvent, EventColorTag, EventType, TaskStatus,
│   │                        # Period, OptimizableEvent, EventPrepStore,
│   │                        # ICalDateParser, TimelineSlotRanker
│   ├── Pomodoro/            # PomodoroConfig, PomodoroDefaults
│   ├── Recurrence/          # RecurrenceRule, RecurrenceEngine, RecurrenceExpander
│   └── Reminders/           # ReminderSettings, ReminderInterval, BadgeCountMode, ...
└── BuboOptimizer/   # Target 2 — Multi-objective GA, deps: BuboDomain
    ├── Anchors/             # AnchorSeeder, AnchorSource
    ├── Constraints/         # Conflict graph, salsa caches, reachability, QueryDB
    ├── Fitness/             # NSGA, hypervolume, surrogate, gradient, feature vec
    │   └── Objectives/      # 16 fitness objectives
    ├── GeneticAlgorithm/    # GA engine (renamed from GACore/). Subdivided 2026-05-13:
    │   ├── Core/           # Chromosome, Population, GAConfiguration, GARandom, slot infra
    │   ├── Operators/      # Selection, Crossover, Mutation, Distance, SymmetryBreaker
    │   ├── Repair/         # CP / CPSAT / regret repair + CPSAT seed
    │   ├── Adaptive/       # Mutation/LNS bandits, tabu memory, LNS destroy
    │   ├── IslandModel/    # IslandModelGA + migration + path relinking
    │   └── Engine/         # GeneticAlgorithm driver, hooks, plateau, QD archive, GNN warm-start
    ├── Learning/            # DPO, calendar embedding, active sampling, chance-buffers, PreferenceLearner
    ├── Models/              # ScheduleGene, ScheduleScenario, ScheduleSnapshot,
    │                        # AppliedSnapshot, OptimizerContext, ... (the GA's internal types)
    ├── Orchestrator/        # BuboOptimizer + extensions (renamed from Core/)
    ├── Reoptimizer/         # IncrementalReoptimizer, TemporalWarmStart, ProactiveReactivePolicy
    ├── Scenarios/           # MAPElitesArchive, ScenarioGenerator
    └── Training/            # TrainingCoordinator, TrainingMetrics, TrainingPersistence

Bubo/                # Target 3 — macOS executable, deps: BuboDomain + BuboOptimizer
├── Composition/             # composition root + app entry + AppKit delegate
├── Application/             # orchestrators (services that own state and side-effects)
│   ├── Agent/, Backlog/, Energy/, Intents/, Learning/, Optimizer/,
│   ├── Pomodoro/, Reminders/, Undo/
├── Infrastructure/          # EventKit, CloudKit, SwiftData, Keychain, Network, fakes
│   ├── Apple/               # EventKit calendar + Reminders wrappers + fakes
│   ├── Cloud/               # CloudKit + CloudSync* + FakeCloudServices
│   ├── Persistence/         # SwiftData @Model classes + store wrappers + UpsertReconciler
│   ├── Reminders/           # EventKitSyncCoordinator + macOS NotificationScheduler
│   └── System/              # Keychain, NetworkMonitor, EventCache, ResourceBundle
├── Presentation/            # SwiftUI views, view models, skins, UI-state coordinators
│   ├── Coordinators/        # BacklogInteractionCoordinator, QuickCaptureBridge, SlotPreviewCache
│   ├── Skins/               # SkinDefinition, CustomSkinLoader, BuiltInSkins resource bundle
│   │   └── Wallpaper/       # WallpaperDefinition + ReminderSettings+Wallpaper bridge
│   │                        # (nested under Skins/ on 2026-05-12 — wallpaper is part of theming)
│   └── Views/               # SwiftUI screens + Components/ + Settings/
└── Resources/               # AppIcon, MenuBarIcon, owl.svg, BuiltInSkins (bundled as resources)
```

Folder boundaries inside each target still define the layer rules below; only target boundaries are compiler-enforced.

The `Tests/` directory (SwiftPM target `BuboTests`) mirrors the 3-target source layout in its own subfolders (regrouped 2026-05-13): `Domain/` → `BuboDomain`; `Optimizer/` → `BuboOptimizer` (with peers `Anchors/`, `Constraints/`, `Fitness/`, `GeneticAlgorithm/`, `Models/`, `Reoptimizer/`, `Training/`); `App/` → `Bubo` (with `Application/` containing `Intents/`, plus `Infrastructure/{Apple,Cloud,Notifications,Persistence}/` and `Presentation/`); and `Integration/` + `Support/` as peers. Tests `@testable import Bubo`, `@testable import BuboDomain`, and `@testable import BuboOptimizer` (all three) so they can reach internal symbols across module boundaries.

## Layer rules

The compiler now enforces target boundaries. The "may import from" column also includes "the targets this code's target depends on":

| Layer | Target | May import from | Must NOT import |
|---|---|---|---|
| **Domain** | `BuboDomain` | Foundation, Observation | SwiftUI, AppKit, CloudKit, SwiftData, EventKit, anything from `BuboOptimizer`/`Bubo` |
| **Optimizer** | `BuboOptimizer` | Foundation, OSLog, BuboDomain | SwiftUI, AppKit, CloudKit, EventKit, anything from `Bubo` |
| **Composition** | `Bubo` | Everything (it wires the graph) | — |
| **Application** | `Bubo` | Foundation, SwiftData, Observation, BuboDomain, BuboOptimizer, Infrastructure | SwiftUI, AppKit, Presentation |
| **Infrastructure** | `Bubo` | Foundation, EventKit, CloudKit, SwiftData, Network, AppKit, BuboDomain, BuboOptimizer | Presentation, Application |
| **Presentation** | `Bubo` | SwiftUI, AppKit, BuboDomain, BuboOptimizer, Application (read-only) | Infrastructure direct (go through Application) |

Inside the `Bubo` executable target, the Composition/Application/Infrastructure/Presentation distinction is **still convention-only** — they live in one module, so the compiler can't reject e.g. an Infrastructure→Presentation import. Folder rules and the in-tree boundary READMEs are the enforcement here. The target-level enforcement only kicks in between `BuboDomain`, `BuboOptimizer`, and `Bubo`.

## What lives where

### `Composition/`
- `App.swift` — `BuboApp` SwiftUI entry point.
- `AppDelegate.swift` — AppKit delegate; full-screen alerts, quick-capture hotkey, dock-leak workaround.
- `AppContainer.swift` — pure-function builder of the service graph. `make()` for production, `build(...)` for tests.

### `Sources/BuboDomain/`
- Value types: `BacklogTask`, `CalendarEvent`, `RecurrenceRule`, `ReminderSettings`, `PomodoroDefaults`, `EventPrepStore`, `Period`, `PomodoroConfig`, `OptimizableEvent`.
- Pure namespaces (`enum`-based): `BacklogLogic`, `RecurrenceEngine`, `RecurrenceExpander`, `TimelineSlotRanker`.
- Parsers: `ICalDateParser`.

`Period`, `PomodoroConfig`, and `OptimizableEvent` moved from `Optimizer/Models/` to Domain on 2026-05-12 (see [`domain-boundaries.md`](domain-boundaries.md) and [`../modules/models.md`](../modules/models.md) for the cycle-break details).

### `Application/`
Orchestrators with state, lifecycles, and notification posting.
`BacklogService`, `ReminderService`, `RemindersSyncService`, `OptimizerService`, `AutoDeferService`, `AgentService`, `EnergyCheckInService`, `PomodoroHistoryService`, `UndoService`.

### `Infrastructure/`
- `Apple/` — EventKit calendar + Reminders wrappers + their fakes.
- `Cloud/` — CloudKit sync monitor, services coordinator, sync protocols + service, fake cloud services.
- `Persistence/` — SwiftData `@Model` classes (`PersistedEvent`, `PersistedBacklogTask`) + store wrappers + `UpsertReconciler` + in-memory fakes.
- `Reminders/` — `EventKitSyncCoordinator`, `NotificationScheduler` (the macOS notification side, not Apple Reminders).
- `System/` — `Keychain`, `NetworkMonitor`, `EventCache` (actor), `ResourceBundle`.

### `Presentation/`
- `Views/` — SwiftUI screens, `Components/`, `Settings/`. The only two view models in the repo (`SettingsViewModel`, `CloudSyncStatusSectionViewModel`) live under `Views/Settings/`; the rest of the UI consumes `@Observable` services directly.
- `Coordinators/` — UI-state holders that used to live under `Services/`: `BacklogInteractionCoordinator` (drag-and-drop), `SlotPreviewCache`, `QuickCaptureBridge`.
- `Skins/` — `SkinDefinition`, `CustomSkinLoader`, `BuiltInSkins/` resource bundle, plus `Wallpaper/` (nested 2026-05-12 — wallpaper is conceptually a skin component): `WallpaperDefinition` SwiftUI catalog + `ReminderSettings+Wallpaper` extension resolver.

### `Sources/BuboOptimizer/`
Self-contained GA + learning stack. Subfolders: `Anchors/`, `Constraints/`, `Fitness/` (+ `Fitness/Objectives/`), `GeneticAlgorithm/`, `Learning/`, `Models/`, `Orchestrator/`, `Reoptimizer/`, `Scenarios/`, `Training/`. See [`../modules/optimizer.md`](../modules/optimizer.md). The `Models/` subfolder is the optimizer-internal derived domain — see [`domain-boundaries.md`](domain-boundaries.md) for how it relates to `BuboDomain`.

Note: `Intents/` is no longer a subfolder here — it moved to `Bubo/Application/Intents/` on 2026-05-12 along with `IntentLearner` (and the then-whole `PreferenceLearner`). In PR #516, the `PreferenceLearner` core class moved back into `BuboOptimizer/Learning/`; only its CloudSync bridge extension (`setupCloudSync()`, `pushToCloudSync()`) remains in `Bubo/Application/Learning/PreferenceLearner.swift`. `BuboOptimizer` still has zero service or persistence deps — the core class imports only Foundation and `BuboDomain`.

`Orchestrator/` (renamed 2026-05-12 from `Core/` to disambiguate from `GeneticAlgorithm/` which was also called "core") holds `BuboOptimizer` and its extension files: `+Learning`, `+Diagnostics`, `+SpecializedPlanning`, `+Feedback`, `+Aliases`, `+Reoptimization`. The split was driven by code size (the original `BuboOptimizer.swift` was 1974 L) and by isolating the diagnostic-logging subsystem from the GA core. `GeneticAlgorithm/` (renamed 2026-05-12 from `GACore/`) is the GA engine itself.

## Known layer violations

| File | Violation | Status |
|---|---|---|
| `Application/Reminders/ReminderService.swift` | `import AppKit` (2026-05-12) | Resolved. The import was dead — only referenced in a comment about `NSPersistentCloudKitContainer`. Removed in the layer-leak cleanup |
| `Application/Reminders/RemindersSyncService+Writeback.swift` | `import EventKit` (2026-05-12) | Resolved. EventKit was not used in code; the file talks to the platform exclusively through the `remindersSource` protocol injected from Infrastructure. Comments still reference `EKEventStore`/`EKAlarm` but no longer compile against the framework |
| `Application/Optimizer/OptimizerService+Settings.swift` | `import SwiftUI` (2026-05-12) | Resolved. Dead import; `BacklogView` reference was a comment. Application layer is now strictly Foundation/SwiftData/Observation/os |
| `Presentation/Views/Skins/Wallpaper/WallpaperDefinition.swift` | (moved out of Domain on 2026-05-11) | Resolved. `WallpaperDefinition` is a presentation-only catalog of SwiftUI colors/gradients; `ReminderSettings` keeps only the `selectedWallpaperID: String`. The ID→definition resolver is a `Presentation/Views/Skins/Wallpaper/` extension on `ReminderSettings` (`ReminderSettings+Wallpaper.swift`) |
| `Presentation/Coordinators/BacklogInteractionCoordinator.swift` | Lives in `Presentation/` and imports `SwiftUI` (`Transferable`) | Compliant after the reorg — it's a UI-state coordinator, not a service. Lives in `Coordinators/` to make this status visible |
| `Presentation/State/SlotPreviewCache.swift` | Imports `Observation` only (no SwiftUI) | Compliant. Lives here because it caches signals consumed by SwiftUI views |
| Keychain identifier `"anthropic-api-key"` (`Application/Agent/AgentService.swift:66`) | Historical name from the pre-DeepSeek era | Kept intentionally — renaming would lose stored secrets on existing installs. Documented in `concepts/agent-service.md` |
| `Infrastructure/Cloud/CloudSyncService.swift` `.shared` singleton | Historic global state inside an Infrastructure type | Flagged for refactor — `OptimizerService+Persistence` and `BacklogService` still call `CloudSyncService.shared.push(...)` directly instead of receiving a coordinator-injected reference |

After the 2026-05-12 cleanup, `grep -rn -E "import (EventKit|AppKit|SwiftUI|CloudKit|UIKit)" Bubo/Application Sources/BuboDomain Sources/BuboOptimizer` returns zero matches — the inner layers are fully framework-clean.

## In-tree boundary READMEs

Two short README files codify the rules at the folder level so a new
contributor can place a change without grepping for the answer:

- `Sources/BuboDomain/Reminders/README.md` — what Domain / Application /
  Infrastructure each own for the Reminders feature.
- `Sources/BuboOptimizer/README.md` — why `Optimizer/` is a peer of
  `Domain/`, what each subfolder holds, and the no-EventKit /
  no-SwiftUI rule for engine code.

Both are listed in `Package.swift`'s `exclude` array so SwiftPM
doesn't flag them as unhandled resources.

## Why this layout

- **Composition root explicit:** every dependency assembled in one file (`AppContainer.swift`). Tests inject in-memory stores via `build(...)`.
- **Domain is pure:** can be consumed by the optimizer, by tests, by any layer, without dragging UI or persistence frameworks. Critical because the GA needs `Sendable` deterministic input.
- **Application owns state, not Infrastructure:** infrastructure objects (Keychain, EventKit, SwiftData containers) are passed *into* application services, never `shared`-singleton'd from inside them. The lone exception is `CloudSyncService.shared` — historic, flagged for refactor.
- **Presentation reads, doesn't write:** views consume `@Observable` services; mutations go through service methods so notification posting and persistence stay in one place.

## Migration history

The flat `Services/` directory (~25 files at the root, mixing pure logic, infrastructure, application services, and UI-state coordinators) was split into the four homes above on 2026-05-11. `Models/Domain/` merged into `Domain/`; `Models/Persistence/` merged into `Infrastructure/Persistence/`; `Views/`, `ViewModels/`, `Skins/` moved under `Presentation/`; `Utils/ICalDateParser.swift` moved into `Domain/`. See `wiki/log.md` for the entry.

A second pass on 2026-05-11 finished the layout: corraled `Infrastructure/` roots into `Cloud/`+`System/`, `Presentation/` roots into `Coordinators/`+`Wallpaper/`, `Optimizer/` roots into `Core/`+`Anchors/`, and re-organised the flat `Tests/BuboTests/` directory into subfolders that mirror the source layout. Mega-file decomposition pass on the same day broke up `Chromosome.swift` (3487 → 3218 L; protocol, distance, free helpers extracted), `BuboOptimizer.swift` (1974 → 982 L; diagnostics, specialised planning, feedback extracted), `GeneticAlgorithm.swift` (1235 → 839 L; `GAConfiguration` and `MultiObjectiveContext` extracted), `DesignSystem.swift` (1228 → 530 L; six `extension DS` files by token category), and `OptimizerService.swift` (995 → 813 L; shadow proposals + persistence extracted). Several `private`/`private(set)` members were relaxed to `internal` so cross-file extensions could call them — every such change is documented inline at the declaration site with a comment naming the sibling file. See `wiki/log.md` for the per-stage breakdown.
