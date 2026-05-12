# Layered structure

> **Kind:** architecture
> **Sources:** Bubo/Composition/, Sources/BuboDomain/, Sources/BuboDomain/Reminders/README.md, Bubo/Application/, Bubo/Application/Reminders/ReminderService.swift, Bubo/Application/Reminders/RemindersSyncService+Writeback.swift, Bubo/Application/Optimizer/OptimizerService+Settings.swift, Bubo/Infrastructure/, Bubo/Presentation/, Sources/BuboOptimizer/, Sources/BuboOptimizer/README.md, Package.swift
> **Last ingest:** 2026-05-12 (rev: Application layer leaks plugged + in-tree boundary READMEs)
> **Related:** [`overview.md`](overview.md), [`domain-boundaries.md`](domain-boundaries.md), [`../modules/services.md`](../modules/services.md), [`../modules/models.md`](../modules/models.md)

## Top-level layout

```
Bubo/
├── Composition/      # composition root + app entry + AppKit delegate
├── Domain/           # pure value types & stateless namespaces (Foundation/Observation only)
├── Application/      # orchestrators (services that own state and side-effects)
├── Infrastructure/   # EventKit, CloudKit, SwiftData, Keychain, Network, fakes
│   ├── Apple/        # EventKit calendar + Reminders wrappers + fakes
│   ├── Cloud/        # CloudKit + CloudSync* + FakeCloudServices
│   ├── Persistence/  # SwiftData @Model classes + store wrappers + UpsertReconciler
│   ├── Reminders/    # EventKitSyncCoordinator + macOS NotificationScheduler
│   └── System/       # Keychain, NetworkMonitor, EventCache, ResourceBundle
├── Presentation/     # SwiftUI views, view models, skins, UI-state coordinators
│   ├── Coordinators/ # BacklogInteractionCoordinator, QuickCaptureBridge, SlotPreviewCache
│   ├── Skins/        # SkinDefinition, CustomSkinLoader, BuiltInSkins resource bundle
│   ├── Views/        # SwiftUI screens + Components/ + Settings/ (Settings/ also holds SettingsViewModel + CloudSyncStatusSectionViewModel)
│   └── Wallpaper/    # WallpaperDefinition + ReminderSettings+Wallpaper bridge
├── Optimizer/        # GA + objectives + constraints + intents (self-contained stack)
│   ├── Anchors/      # AnchorSeeder, AnchorSource
│   ├── Constraints/         # Conflict graph, salsa caches, reachability, QueryDB
│   ├── Fitness/             # NSGA, hypervolume, surrogate, gradient, feature vec
│   ├── GeneticAlgorithm/    # GA, Chromosome, caches, dispatch presets (renamed from GACore/)
│   ├── Orchestrator/        # BuboOptimizer + extensions (renamed from Core/)
│   ├── Intents/      # Intent, IntentGraph, Pomodoro, QuickActions
│   ├── Learning/     # PreferenceLearner, DPO, calendar embedding, intent learner
│   ├── Models/       # OptimizableEvent, ScheduleTypes, EventConversion (the GA's domain)
│   ├── Reoptimizer/  # IncrementalReoptimizer, TemporalWarmStart, ProactiveReactivePolicy
│   ├── Scenarios/    # MAPElitesArchive, ScenarioGenerator
│   └── Training/     # TrainingCoordinator, TrainingMetrics, TrainingPersistence
└── Resources/        # AppIcon, MenuBarIcon, owl.svg
```

The whole tree is a single SPM target (`Package.swift:10`, `path: "Bubo"`); SPM picks up all `.swift` files recursively. Folders affect navigation, not compilation or access control.

The `Tests/BuboTests/` target mirrors this layout in its own subfolders (`GACore/`, `Fitness/`, `Constraints/`, `Intents/`, `Reoptimizer/`, `Training/`, `Anchors/`, `Models/`, `Domain/`, `Application/`, `Presentation/`, `Infrastructure/{Apple,Cloud,Persistence,Reminders}/`, `Integration/`, `Support/`). The test subfolder `GACore/` predates the 2026-05-12 source rename `GACore/ → GeneticAlgorithm/` and was deliberately not touched in that pass — same content, just out of sync by one rename.

## Layer rules

| Layer | May import from | Must NOT import |
|---|---|---|
| **Composition** | Everything (it wires the graph) | — |
| **Domain** | Foundation, Observation, EventKit-data-only types | SwiftUI, AppKit, CloudKit, SwiftData, SwiftUI services |
| **Application** | Foundation, SwiftData, Observation, Domain, Infrastructure | SwiftUI, AppKit, Presentation |
| **Infrastructure** | Foundation, EventKit, CloudKit, SwiftData, Network, AppKit (for hotkeys/etc.), Domain | Presentation, Application |
| **Presentation** | SwiftUI, AppKit, Domain, Application (read-only) | Infrastructure direct (go through Application) |
| **Optimizer** | Foundation, Domain | SwiftUI, AppKit, CloudKit, Application |

## What lives where

### `Composition/`
- `App.swift` — `BuboApp` SwiftUI entry point.
- `AppDelegate.swift` — AppKit delegate; full-screen alerts, quick-capture hotkey, dock-leak workaround.
- `AppContainer.swift` — pure-function builder of the service graph. `make()` for production, `build(...)` for tests.

### `Domain/`
- Value types: `BacklogTask`, `CalendarEvent`, `RecurrenceRule`, `ReminderSettings`, `PomodoroDefaults`, `EventPrepStore`.
- Pure namespaces (`enum`-based): `BacklogLogic`, `RecurrenceEngine`, `RecurrenceExpander`, `TimelineSlotRanker`.
- Parsers: `ICalDateParser`.

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
- `Skins/` — `SkinDefinition`, `CustomSkinLoader`, `BuiltInSkins/` resource bundle.
- `Wallpaper/` — `WallpaperDefinition` SwiftUI catalog + `ReminderSettings+Wallpaper` extension resolver.

### `Optimizer/`
Self-contained GA + intents + learning stack. Subfolders: `Anchors/`, `Constraints/`, `Fitness/`, `GeneticAlgorithm/`, `Intents/`, `Learning/`, `Models/`, `Orchestrator/`, `Reoptimizer/`, `Scenarios/`, `Training/`. See [`../modules/optimizer.md`](../modules/optimizer.md). The `Models/` subfolder is the optimizer-internal derived domain — see [`domain-boundaries.md`](domain-boundaries.md) for how it relates to `Sources/BuboDomain/`.

`Orchestrator/` (renamed 2026-05-12 from `Core/` to disambiguate from `GeneticAlgorithm/` which was also called "core") holds `BuboOptimizer` and its extension files: `+Learning`, `+Diagnostics`, `+SpecializedPlanning`, `+Feedback`, `+Aliases`, `+Reoptimization`. The split was driven by code size (the original `BuboOptimizer.swift` was 1974 L) and by isolating the diagnostic-logging subsystem from the GA core. `GeneticAlgorithm/` (renamed 2026-05-12 from `GACore/`) is the GA engine itself.

## Known layer violations

| File | Violation | Status |
|---|---|---|
| `Application/Reminders/ReminderService.swift` | `import AppKit` (2026-05-12) | Resolved. The import was dead — only referenced in a comment about `NSPersistentCloudKitContainer`. Removed in the layer-leak cleanup |
| `Application/Reminders/RemindersSyncService+Writeback.swift` | `import EventKit` (2026-05-12) | Resolved. EventKit was not used in code; the file talks to the platform exclusively through the `remindersSource` protocol injected from Infrastructure. Comments still reference `EKEventStore`/`EKAlarm` but no longer compile against the framework |
| `Application/Optimizer/OptimizerService+Settings.swift` | `import SwiftUI` (2026-05-12) | Resolved. Dead import; `BacklogView` reference was a comment. Application layer is now strictly Foundation/SwiftData/Observation/os |
| `Presentation/Wallpaper/WallpaperDefinition.swift` | (moved out of Domain on 2026-05-11) | Resolved. `WallpaperDefinition` is a presentation-only catalog of SwiftUI colors/gradients; `ReminderSettings` keeps only the `selectedWallpaperID: String`. The ID→definition resolver is a `Presentation/Wallpaper/` extension on `ReminderSettings` (`ReminderSettings+Wallpaper.swift`) |
| `Presentation/Coordinators/BacklogInteractionCoordinator.swift` | Lives in `Presentation/` and imports `SwiftUI` (`Transferable`) | Compliant after the reorg — it's a UI-state coordinator, not a service. Lives in `Coordinators/` to make this status visible |
| `Presentation/Coordinators/SlotPreviewCache.swift` | Imports `Observation` only (no SwiftUI) | Compliant. Lives here because it caches signals consumed by SwiftUI views |
| Keychain identifier `"anthropic-api-key"` (`Application/Agent/AgentService.swift:66`) | Historical name from the pre-DeepSeek era | Kept intentionally — renaming would lose stored secrets on existing installs. Documented in `concepts/agent-service.md` |
| `Infrastructure/Cloud/CloudSyncService.swift` `.shared` singleton | Historic global state inside an Infrastructure type | Flagged for refactor — `OptimizerService+Persistence` and `BacklogService` still call `CloudSyncService.shared.push(...)` directly instead of receiving a coordinator-injected reference |

After the 2026-05-12 cleanup, `grep -rn -E "import (EventKit|AppKit|SwiftUI|CloudKit|UIKit)" Bubo/Application Bubo/Domain Bubo/Optimizer` returns zero matches — the inner layers are fully framework-clean.

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
