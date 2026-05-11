# Wiki index

Catalog of every page. One-line summary, grouped by kind. Agents: update this on every ingest. See `../AGENTS.md` §3.

## Architecture

- [`architecture/overview.md`](architecture/overview.md) — composition root, observable services, notification bus, persistence layers
- [`architecture/persistence.md`](architecture/persistence.md) — SwiftData containers, CloudKit sync, store protocols, reconciliation
- [`architecture/event-pipeline.md`](architecture/event-pipeline.md) — how an `EKEvent` becomes a `CalendarEvent` becomes a UI row and an alert

## Modules

One page per top-level subdirectory of `Bubo/`.

- [`modules/app.md`](modules/app.md) — `App.swift`, `AppDelegate.swift`, `AppContainer.swift`, `ResourceBundle.swift`
- [`modules/models.md`](modules/models.md) — `Models/Domain/`, `Models/Persistence/`: domain types, SwiftData mirrors
- [`modules/services.md`](modules/services.md) — `Services/`: orchestrators, EventKit wrappers, persistence stores, sync
- [`modules/optimizer.md`](modules/optimizer.md) — `Optimizer/`: GA core, constraints, fitness objectives, intents, learning
- [`modules/views.md`](modules/views.md) — `Views/`: SwiftUI screens, settings tabs, components
- [`modules/viewmodels.md`](modules/viewmodels.md) — `ViewModels/`: settings & cloud-sync state
- [`modules/skins.md`](modules/skins.md) — `Skins/`: theme schema, built-in skins, JSON loader
- [`modules/utils.md`](modules/utils.md) — `Utils/`: misc helpers
- [`modules/tests.md`](modules/tests.md) — `Tests/OptimizerTests/`: what is covered, what isn't
- [`modules/proxy.md`](modules/proxy.md) — `proxy/`: built-in Claude API proxy server

## Concepts

Cross-cutting features and patterns spanning multiple modules.

- [`concepts/menu-bar-popover.md`](concepts/menu-bar-popover.md) — the timeline-in-menubar entry point
- [`concepts/full-screen-alerts.md`](concepts/full-screen-alerts.md) — pre-meeting takeover screen (J4)
- [`concepts/join-ribbon.md`](concepts/join-ribbon.md) — post-join ribbon (J1)
- [`concepts/quick-capture.md`](concepts/quick-capture.md) — global hotkey ⌃⇧⌘Space task capture
- [`concepts/pomodoro.md`](concepts/pomodoro.md) — five rhythms, scheduling, timer window
- [`concepts/genetic-algorithm.md`](concepts/genetic-algorithm.md) — chromosome, population, selection, crossover, mutation, repair
- [`concepts/fitness-objectives.md`](concepts/fitness-objectives.md) — the 15+ objectives the GA optimizes against
- [`concepts/intents.md`](concepts/intents.md) — intent DSL, compilation, learning, NL bridge
- [`concepts/agent-service.md`](concepts/agent-service.md) — Claude integration, built-in vs own-key, rate limits
- [`concepts/cloudkit-sync.md`](concepts/cloudkit-sync.md) — SwiftData + CloudKit, monitor, reconciliation
- [`concepts/recurrence.md`](concepts/recurrence.md) — two recurrence systems: tag-based for tasks, RFC 5545 for events
- [`concepts/undo.md`](concepts/undo.md) — `UndoService`, toast surface, PRINCIPLES §5
- [`concepts/skins-system.md`](concepts/skins-system.md) — what skins can and cannot change (PRINCIPLES §10)
- [`concepts/design-principles.md`](concepts/design-principles.md) — distillation of `docs/design/PRINCIPLES.md` for code review
- [`concepts/notifications-bus.md`](concepts/notifications-bus.md) — `NotificationCenter` topics that glue services to UI
