# Layered structure

> **Kind:** architecture
> **Sources:** Bubo/Composition/, Bubo/Domain/, Bubo/Application/, Bubo/Infrastructure/, Bubo/Presentation/, Bubo/Optimizer/, Package.swift
> **Last ingest:** 2026-05-12 (rev: bounded-context restructure + mega-file split)
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
│   ├── ViewModels/   # SettingsViewModel, CloudSyncStatusSectionViewModel
│   ├── Views/        # SwiftUI screens + Components/ + Settings/
│   └── Wallpaper/    # WallpaperDefinition + ReminderSettings+Wallpaper bridge
├── Optimizer/        # GA + objectives + constraints + intents (self-contained stack)
│   ├── Anchors/      # AnchorSeeder, AnchorSource
│   ├── Constraints/  # Conflict graph, salsa caches, reachability, QueryDB
│   ├── Core/         # BuboOptimizer + extensions (Diagnostics/Feedback/Learning/SpecializedPlanning)
│   ├── Fitness/      # NSGA, hypervolume, surrogate, gradient, feature vec
│   ├── GACore/       # GeneticAlgorithm, Chromosome, caches, dispatch presets
│   ├── Intents/      # Intent, IntentGraph, Pomodoro, QuickActions
│   ├── Learning/     # PreferenceLearner, DPO, calendar embedding, intent learner
│   ├── Models/       # OptimizableEvent, ScheduleTypes, EventConversion (the GA's domain)
│   ├── Reoptimizer/  # IncrementalReoptimizer, TemporalWarmStart, ProactiveReactivePolicy
│   ├── Scenarios/    # MAPElitesArchive, ScenarioGenerator
│   └── Training/     # TrainingCoordinator, TrainingMetrics, TrainingPersistence
└── Resources/        # AppIcon, MenuBarIcon, owl.svg
```

The whole tree is a single SPM target (`Package.swift:10`, `path: "Bubo"`); SPM picks up all `.swift` files recursively. Folders affect navigation, not compilation or access control.

The `Tests/OptimizerTests/` target mirrors this layout in its own subfolders (`GACore/`, `Fitness/`, `Constraints/`, `Intents/`, `Reoptimizer/`, `Training/`, `Anchors/`, `Models/`, `Domain/`, `Application/`, `Presentation/`, `Infrastructure/{Apple,Cloud,Persistence,Reminders}/`, `Integration/`, `Support/`).

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
- `Views/` — SwiftUI screens, `Components/`, `Settings/`.
- `ViewModels/` — only `SettingsViewModel` + `CloudSyncStatusSectionViewModel` (the codebase otherwise consumes `@Observable` services directly).
- `Coordinators/` — UI-state holders that used to live under `Services/`: `BacklogInteractionCoordinator` (drag-and-drop), `SlotPreviewCache`, `QuickCaptureBridge`.
- `Skins/` — `SkinDefinition`, `CustomSkinLoader`, `BuiltInSkins/` resource bundle.
- `Wallpaper/` — `WallpaperDefinition` SwiftUI catalog + `ReminderSettings+Wallpaper` extension resolver.

### `Optimizer/`
Self-contained GA + intents + learning stack. Subfolders: `Anchors/`, `Constraints/`, `Core/`, `Fitness/`, `GACore/`, `Intents/`, `Learning/`, `Models/`, `Reoptimizer/`, `Scenarios/`, `Training/`. See [`../modules/optimizer.md`](../modules/optimizer.md). The `Models/` subfolder is the optimizer-internal derived domain — see [`domain-boundaries.md`](domain-boundaries.md) for how it relates to `Bubo/Domain/`.

`Core/` holds `BuboOptimizer` and its extension files: `+Learning`, `+Diagnostics`, `+SpecializedPlanning`, `+Feedback`. The split was driven by code size (the original `BuboOptimizer.swift` was 1974 L) and by isolating the diagnostic-logging subsystem from the GA core.

## Known layer violations

| File | Violation | Status |
|---|---|---|
| `Presentation/Wallpaper/WallpaperDefinition.swift` | (moved out of Domain on 2026-05-11) | Resolved. `WallpaperDefinition` is a presentation-only catalog of SwiftUI colors/gradients; `ReminderSettings` keeps only the `selectedWallpaperID: String`. The ID→definition resolver is a `Presentation/Wallpaper/` extension on `ReminderSettings` (`ReminderSettings+Wallpaper.swift`) |
| `Presentation/Coordinators/BacklogInteractionCoordinator.swift` | Lives in `Presentation/` and imports `SwiftUI` (`Transferable`) | Compliant after the reorg — it's a UI-state coordinator, not a service. Lives in `Coordinators/` to make this status visible |
| `Presentation/Coordinators/SlotPreviewCache.swift` | Imports `Observation` only (no SwiftUI) | Compliant. Lives here because it caches signals consumed by SwiftUI views |
| Keychain identifier `"anthropic-api-key"` (`Application/AgentService.swift:61`) | Historical name from the pre-DeepSeek era | Kept intentionally — renaming would lose stored secrets on existing installs. Documented in `concepts/agent-service.md` |
| `Infrastructure/Cloud/CloudSyncService.swift` `.shared` singleton | Historic global state inside an Infrastructure type | Flagged for refactor — `OptimizerService+Persistence` and `BacklogService` still call `CloudSyncService.shared.push(...)` directly instead of receiving a coordinator-injected reference |

## Why this layout

- **Composition root explicit:** every dependency assembled in one file (`AppContainer.swift`). Tests inject in-memory stores via `build(...)`.
- **Domain is pure:** can be consumed by the optimizer, by tests, by any layer, without dragging UI or persistence frameworks. Critical because the GA needs `Sendable` deterministic input.
- **Application owns state, not Infrastructure:** infrastructure objects (Keychain, EventKit, SwiftData containers) are passed *into* application services, never `shared`-singleton'd from inside them. The lone exception is `CloudSyncService.shared` — historic, flagged for refactor.
- **Presentation reads, doesn't write:** views consume `@Observable` services; mutations go through service methods so notification posting and persistence stay in one place.

## Migration history

The flat `Services/` directory (~25 files at the root, mixing pure logic, infrastructure, application services, and UI-state coordinators) was split into the four homes above on 2026-05-11. `Models/Domain/` merged into `Domain/`; `Models/Persistence/` merged into `Infrastructure/Persistence/`; `Views/`, `ViewModels/`, `Skins/` moved under `Presentation/`; `Utils/ICalDateParser.swift` moved into `Domain/`. See `wiki/log.md` for the entry.

A second pass on 2026-05-11 finished the layout: corraled `Infrastructure/` roots into `Cloud/`+`System/`, `Presentation/` roots into `Coordinators/`+`Wallpaper/`, `Optimizer/` roots into `Core/`+`Anchors/`, and re-organised the flat `Tests/OptimizerTests/` directory into subfolders that mirror the source layout. Mega-file decomposition pass on the same day broke up `Chromosome.swift` (3487 → 3218 L; protocol, distance, free helpers extracted), `BuboOptimizer.swift` (1974 → 982 L; diagnostics, specialised planning, feedback extracted), `GeneticAlgorithm.swift` (1235 → 839 L; `GAConfiguration` and `MultiObjectiveContext` extracted), `DesignSystem.swift` (1228 → 530 L; six `extension DS` files by token category), and `OptimizerService.swift` (995 → 813 L; shadow proposals + persistence extracted). Several `private`/`private(set)` members were relaxed to `internal` so cross-file extensions could call them — every such change is documented inline at the declaration site with a comment naming the sibling file. See `wiki/log.md` for the per-stage breakdown.
