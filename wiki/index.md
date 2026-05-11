# Wiki index

Catalog of every page. One-line summary, grouped by kind. Agents: update this on every ingest. See `../AGENTS.md` §3.

## Architecture

- [`architecture/overview.md`](architecture/overview.md) — composition root, observable services, notification bus, persistence layers
- [`architecture/layered-structure.md`](architecture/layered-structure.md) — Composition / Domain / Application / Infrastructure / Presentation layout and rules
- [`architecture/domain-boundaries.md`](architecture/domain-boundaries.md) — `Bubo/Domain/` vs `Bubo/Optimizer/Models/`: what lives where and how `EventConversion` bridges them
- [`architecture/BODY-SPLIT-PLAN.md`](architecture/BODY-SPLIT-PLAN.md) — executable plan for splitting `MenuBarView` and `BacklogFullscreenView` bodies (18 PRs)
- [`architecture/persistence.md`](architecture/persistence.md) — SwiftData containers, CloudKit sync, store protocols, reconciliation
- [`architecture/event-pipeline.md`](architecture/event-pipeline.md) — how an `EKEvent` becomes a `CalendarEvent` becomes a UI row and an alert

## Modules

The source tree is layered (see [`architecture/layered-structure.md`](architecture/layered-structure.md)). The module pages below predate that refactor; they remain useful topic-clusters and their per-file rows cite the new layered paths.

- [`modules/app.md`](modules/app.md) — `Composition/`: `App.swift`, `AppDelegate.swift`, `AppContainer.swift`, plus `Infrastructure/System/ResourceBundle.swift`
- [`modules/models.md`](modules/models.md) — `Domain/` + `Infrastructure/Persistence/`: domain types and SwiftData mirrors
- [`modules/services.md`](modules/services.md) — `Application/` + `Infrastructure/` (+ 4 pure namespaces in `Domain/` + 3 UI coordinators in `Presentation/`)
- [`modules/optimizer.md`](modules/optimizer.md) — `Optimizer/`: GA core, constraints, fitness objectives, intents, learning
- [`modules/views.md`](modules/views.md) — `Presentation/Views/`: SwiftUI screens, settings tabs, components
- [`modules/viewmodels.md`](modules/viewmodels.md) — `Presentation/ViewModels/`: settings & cloud-sync state
- [`modules/skins.md`](modules/skins.md) — `Presentation/Skins/`: theme schema, built-in skins, JSON loader
- [`modules/utils.md`](modules/utils.md) — retired; `ICalDateParser` moved to `Domain/`
- [`modules/tests.md`](modules/tests.md) — `Tests/OptimizerTests/`: what is covered, what isn't
- [`modules/proxy.md`](modules/proxy.md) — `proxy/`: Cloudflare-Worker proxy to DeepSeek

## Concepts

Cross-cutting features and patterns spanning multiple modules.

- [`concepts/menu-bar-popover.md`](concepts/menu-bar-popover.md) — the timeline-in-menubar entry point
- [`concepts/full-screen-alerts.md`](concepts/full-screen-alerts.md) — pre-meeting takeover screen (J4)
- [`concepts/join-ribbon.md`](concepts/join-ribbon.md) — post-join ribbon (J1)
- [`concepts/quick-capture.md`](concepts/quick-capture.md) — global hotkey ⌃⇧⌘Space task capture
- [`concepts/pomodoro.md`](concepts/pomodoro.md) — five rhythms, scheduling, timer window
- [`concepts/genetic-algorithm.md`](concepts/genetic-algorithm.md) — chromosome, population, selection, crossover, mutation, repair
- [`concepts/fitness-objectives.md`](concepts/fitness-objectives.md) — all 16 objectives, defaults, partitioning traits, soft/hard pairs
- [`concepts/constraints.md`](concepts/constraints.md) — hard constraints, Salsa caches, conflict graph, CPSAT repair
- [`concepts/intents.md`](concepts/intents.md) — intent DSL, 8-stage compilation, learning, NL bridge
- [`concepts/agent-service.md`](concepts/agent-service.md) — Claude integration, built-in vs own-key, rate limits
- [`concepts/cloudkit-sync.md`](concepts/cloudkit-sync.md) — SwiftData + CloudKit, monitor, reconciliation
- [`concepts/recurrence.md`](concepts/recurrence.md) — two recurrence systems: tag-based for tasks, RFC 5545 for events
- [`concepts/undo.md`](concepts/undo.md) — `UndoService`, toast surface, PRINCIPLES §5
- [`concepts/skins-system.md`](concepts/skins-system.md) — what skins can and cannot change (PRINCIPLES §10)
- [`concepts/design-principles.md`](concepts/design-principles.md) — distillation of `docs/design/PRINCIPLES.md` for code review
- [`concepts/notifications-bus.md`](concepts/notifications-bus.md) — `NotificationCenter` topics that glue services to UI
