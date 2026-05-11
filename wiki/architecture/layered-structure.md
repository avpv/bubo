# Layered structure

> **Kind:** architecture
> **Sources:** Bubo/Composition/, Bubo/Domain/, Bubo/Application/, Bubo/Infrastructure/, Bubo/Presentation/, Bubo/Optimizer/, Package.swift
> **Last ingest:** 2026-05-11
> **Related:** [`overview.md`](overview.md), [`../modules/services.md`](../modules/services.md), [`../modules/models.md`](../modules/models.md)

## Top-level layout

```
Bubo/
├── Composition/      # 3 files — composition root + app entry + AppKit delegate
├── Domain/           # 12 files — pure value types & stateless namespaces
├── Application/      # 8 files — orchestrators (services that own state and side-effects)
├── Infrastructure/   # 27 files — EventKit, CloudKit, SwiftData, Keychain, Network, fakes
├── Presentation/     # 78 files — SwiftUI views, view models, skins, UI-state coordinators
├── Optimizer/        # 99 files — GA + objectives + constraints + intents (separate stack)
└── Resources/        # AppIcon, MenuBarIcon, owl.svg
```

The whole tree is a single SPM target (`Package.swift:10`, `path: "Bubo"`); SPM picks up all `.swift` files recursively. Folders affect navigation, not compilation or access control.

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
- Top-level: `Keychain`, `NetworkMonitor`, `EventCache` (actor), `CloudKitSyncMonitor`, `CloudServicesCoordinator`, `CloudSyncProtocols`, `CloudSyncService`, `FakeCloudServices`, `ResourceBundle`.
- `Apple/` — EventKit calendar + Reminders wrappers + their fakes.
- `Persistence/` — SwiftData `@Model` classes (`PersistedEvent`, `PersistedBacklogTask`) + store wrappers + `UpsertReconciler` + in-memory fakes.
- `Reminders/` — `EventKitSyncCoordinator`, `NotificationScheduler` (the macOS notification side, not Apple Reminders).

### `Presentation/`
- `Views/` — SwiftUI screens, `Components/`, `Settings/`.
- `ViewModels/` — only `SettingsViewModel` + `CloudSyncStatusSectionViewModel` (the codebase otherwise consumes `@Observable` services directly).
- `Skins/` — `SkinDefinition`, `CustomSkinLoader`, `BuiltInSkins/` resource bundle.
- UI-state coordinators that used to live under `Services/`: `BacklogInteractionCoordinator` (drag-and-drop), `SlotPreviewCache`, `QuickCaptureBridge`.

### `Optimizer/`
Self-contained GA + intents + learning stack. Subfolders: `GACore/`, `Fitness/`, `Constraints/`, `Intents/`, `Learning/`, `Reoptimizer/`, `Training/`, `Scenarios/`, `Models/`. See [`../modules/optimizer.md`](../modules/optimizer.md).

## Known layer violations

| File | Violation | Status |
|---|---|---|
| `Presentation/WallpaperDefinition.swift` | (moved out of Domain on 2026-05-11) | Resolved. `WallpaperDefinition` is a presentation-only catalog of SwiftUI colors/gradients; `ReminderSettings` keeps only the `selectedWallpaperID: String`. The ID→definition resolver is a `Presentation/` extension on `ReminderSettings` (`ReminderSettings+Wallpaper.swift`) |
| `Presentation/BacklogInteractionCoordinator.swift` | Lives in `Presentation/` and imports `SwiftUI` (`Transferable`) | Compliant after the reorg — it's a UI-state coordinator, not a service |
| `Presentation/SlotPreviewCache.swift` | Imports `Observation` only (no SwiftUI) | Compliant. Lives here because it caches signals consumed by SwiftUI views |
| Keychain identifier `"anthropic-api-key"` (`Application/AgentService.swift:61`) | Historical name from the pre-DeepSeek era | Kept intentionally — renaming would lose stored secrets on existing installs. Documented in `concepts/agent-service.md` |

## Why this layout

- **Composition root explicit:** every dependency assembled in one file (`AppContainer.swift`). Tests inject in-memory stores via `build(...)`.
- **Domain is pure:** can be consumed by the optimizer, by tests, by any layer, without dragging UI or persistence frameworks. Critical because the GA needs `Sendable` deterministic input.
- **Application owns state, not Infrastructure:** infrastructure objects (Keychain, EventKit, SwiftData containers) are passed *into* application services, never `shared`-singleton'd from inside them. The lone exception is `CloudSyncService.shared` — historic, flagged for refactor.
- **Presentation reads, doesn't write:** views consume `@Observable` services; mutations go through service methods so notification posting and persistence stay in one place.

## Migration history

The flat `Services/` directory (~25 files at the root, mixing pure logic, infrastructure, application services, and UI-state coordinators) was split into the four homes above on 2026-05-11. `Models/Domain/` merged into `Domain/`; `Models/Persistence/` merged into `Infrastructure/Persistence/`; `Views/`, `ViewModels/`, `Skins/` moved under `Presentation/`; `Utils/ICalDateParser.swift` moved into `Domain/`. See `wiki/log.md` for the entry.
