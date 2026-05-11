# Module: Services

> **Kind:** module
> **Sources:** Bubo/Application/, Bubo/Infrastructure/Apple/, Bubo/Infrastructure/Cloud/, Bubo/Infrastructure/Persistence/, Bubo/Infrastructure/Reminders/, Bubo/Infrastructure/System/, Bubo/Presentation/Coordinators/, Bubo/Domain/
> **Last ingest:** 2026-05-12 (rev: bounded-context restructure + mega-file split)
> **Related:** [`../architecture/overview.md`](../architecture/overview.md), [`../architecture/event-pipeline.md`](../architecture/event-pipeline.md), [`../concepts/notifications-bus.md`](../concepts/notifications-bus.md), [`optimizer.md`](optimizer.md), [`../concepts/cloudkit-sync.md`](../concepts/cloudkit-sync.md)

## Layout

The former flat `Services/` directory was split into four layered homes; in 2026-05 the `Infrastructure/` and `Presentation/` roots were further corraled into subfolders so the layer's responsibilities are visible from `ls`:

```
Application/                    # one subfolder per bounded context as of 2026-05-12:
                                #   Agent/   AgentService.swift + AgentAPITypes/AgentError/AgentRecipeToolSchema
                                #   Backlog/ BacklogService.swift + BacklogService+Mutations.swift + AutoDeferService.swift
                                #   Optimizer/ OptimizerService.swift + +Persistence + +ShadowProposals
                                #                                   + +Settings + +Execute + +ApplyScenario
                                #   Reminders/ ReminderService.swift + RemindersSyncService.swift + +Writeback
                                #   Pomodoro/ PomodoroHistoryService.swift
                                #   Energy/  EnergyCheckInService.swift
                                #   Undo/    UndoService.swift
Infrastructure/
├── Apple/                      # EventKit + Reminders wrappers, protocol-based sources
│   └── Fakes/                  # Fake{Calendar,Reminders}EventSource test doubles
├── Cloud/                      # CloudKit monitor, services coordinator, sync protocols + service
│   └── Fakes/                  # FakeCloudServices test double
├── Persistence/                # SwiftData stores + @Model classes + reconciler + in-memory fakes
├── Reminders/                  # EventKit sync coordinator, per-event alert scheduler
└── System/                     # Keychain, NetworkMonitor, EventCache (actor), ResourceBundle
Domain/                         # 4 pure-namespace services migrated here: BacklogLogic,
                                # RecurrenceEngine, RecurrenceExpander, TimelineSlotRanker
Presentation/Coordinators/      # 3 UI-state coordinators: BacklogInteractionCoordinator,
                                # QuickCaptureBridge, SlotPreviewCache
```

Note: the `Infrastructure/Reminders/` directory is named after *macOS notifications/reminders* (alerts and EventKit sync timing), not Apple Reminders. The Apple-Reminders bridge service (`RemindersSyncService.swift`) lives in `Application/`.

## Orchestrators (the public surface)

| Service | Owns | Read by |
|---|---|---|
| `ReminderService` (`ReminderService.swift:29`) | `upcomingEvents`, `localEvents`, plus four sub-services: `EventKitSyncCoordinator`, `NotificationScheduler`, three persistence stores | `MenuBarView`, `OptimizerService`, `AppDelegate` |
| `BacklogService` (`BacklogService.swift:10`) | `tasks`, `BacklogTaskStore`. Posts `.taskAdded` / `.taskUpdated` / `.taskRemoved` / `.taskCompleted` / `.taskScheduleChanged`. Reconciles after CloudKit import via monotonic field handling. Stale-task age threshold lives in one place: `staleTaskThresholdDays = 14` + `staleTaskCutoff` helper (shared by `staleTasks` and `dropStaleTasks`). Mutation surface (add/update/remove/complete/freeze/schedule/reorder + silent-* helpers used by `RemindersSyncService` to dodge sync echoes) lives in `BacklogService+Mutations.swift` | `BacklogFullscreenView`, `OptimizerService`, `EditTaskView` |
| `OptimizerService` (`OptimizerService.swift`) | `BuboOptimizer`, `IntentLearner`, `scenarios`, `shadowProposal`. After the 2026-05-12 split, the service core is 320 L and the rest lives in five sibling files: `+ShadowProposals` (background `previewRequest`, `clearShadowProposal`, `switchToAppliedScenario`); `+Persistence` (`saveSettings`/`loadSettings`/`SavedSettings`); `+Settings` (persisted optimizer toggles + CloudKit cross-device sync); `+Execute` (`executeRequest` pipeline + `instantReflow`/`executeDryRun`/`previewScenarios`/`applyPreviewedScenario`/`runWeekMockSimulator`); `+ApplyScenario` (`applyScenario`/`rejectScenario` commit paths). `private(set)` was dropped on `isOptimizing`/`error`/`lastSnapshot`/`lastAppliedRequest`/`selectedScenarioIndex`/`lastOptimizationDate` so the sibling files can mutate run state. | `MenuBarView` (ghost previews), `OptimizerTabView`, `CommandPalette` |
| `RemindersSyncService` (`RemindersSyncService.swift:57`) | Reminders→Bubo import path: sync timer, external-edit merging, dismissal tracking. The inverse Bubo→Reminders writeback (completion/export/edit/schedule/remove + alarm-settings sweep + linkage helpers) lives in `RemindersSyncService+Writeback.swift`. Posts `didImportTasks` | `AppDelegate`, `RemindersTabView`, `AppleRemindersTabView` |
| `AgentService` (`AgentService.swift:19`) | **DeepSeek** client (OpenAI-compatible) + rate-limit window. Two modes: `.builtIn` (via Bubo Cloudflare-Worker proxy) and `.ownKey` (direct `api.deepseek.com`, key in Keychain under historical id `"anthropic-api-key"` at `:61`). Endpoint `:94` (`api.deepseek.com/chat/completions`), `:126` (`model: "deepseek-chat"`), `:396` ("Add your DeepSeek API key"). The OpenAI-compatible request/response types, `RequestToolSchema` JSON schema, and `AgentError` cases were lifted to sibling files (`AgentAPITypes.swift`, `AgentRecipeToolSchema.swift`, `AgentError.swift`) so the service file is just the @Observable surface | `AITabView`, `CommandPalette` |

## Apple (`Infrastructure/Apple/`)

| File | Type+line | Role |
|---|---|---|
| `AppleCalendarService.swift` | `class AppleCalendarService` (`:13`) | EventKit calendar access via a shared `EKEventStore`. Observes external changes. Posts `calendarDataChanged` and `authorizationDidChange` |
| `AppleRemindersService.swift` | `@MainActor @Observable final class AppleRemindersService` (`:14`) | Read/write access to Apple Reminders via EventKit; **reuses the shared `EKEventStore`**. Posts `remindersDataChanged` and `authorizationDidChange` |
| `CalendarEventSource.swift` | `protocol CalendarEventSource` (`:18`) | Test-seam abstraction over `AppleCalendarService` |
| `FakeCalendarEventSource.swift` | `final class FakeCalendarEventSource` (`:14`) | Test/preview double with invocation recording |
| `RemindersEventSource.swift` | `@MainActor protocol RemindersEventSource` (`:24`) | Test-seam abstraction over `AppleRemindersService` |
| `FakeRemindersEventSource.swift` | `@MainActor final class FakeRemindersEventSource` (`:10`) | Test double with invocation recording and a local task store |

## Persistence (`Infrastructure/Persistence/`)

All store classes are `@MainActor final class`. All store protocols in `Stores.swift` are `@MainActor`.

| File | Type+line | Role |
|---|---|---|
| `Stores.swift` | `protocol LocalEventStoring` (`:19`) + others | Repository abstractions for local events, excluded occurrences, reminder overrides, attribute overrides |
| `LocalEventStore.swift` | `LocalEventStore` (`:22`) | Repository for user-created local events. Isolates `ReminderService` from SwiftData |
| `BacklogTaskStore.swift` | `BacklogTaskStore` (`:18`) | SwiftData-backed persistence primitives for `BacklogService` |
| `ExcludedOccurrenceStore.swift` | `ExcludedOccurrenceStore` (`:15`) | Per-occurrence tombstones for recurring-event exclusions |
| `ReminderOverrideStore.swift` | `ReminderOverrideStore` (`:13`) | Per-event reminder-time overrides |
| `EventAttributeOverrideStore.swift` | `EventAttributeOverrideStore` (`:13`) | Per-event color / context overlays on external Calendar events |
| `InMemoryStores.swift` | `InMemoryLocalEventStore` (`:17`) + others | Test doubles for three store protocols; live in app target for previews |
| `UpsertReconciler.swift` | `enum UpsertReconciler` (`:23`) | Single-pass `reconcile(...)` — dedup + insert + update + delete. Called from every store save path to handle CloudKit-merge duplicates |

## Reminders (`Infrastructure/Reminders/`)

| File | Type+line | Role |
|---|---|---|
| `EventKitSyncCoordinator.swift` | `@MainActor @Observable final class EventKitSyncCoordinator` (`:24`) | Owns EventKit sync timer + post-sync cascade + in-flight refresh task + disk-cache write-back |
| `NotificationScheduler.swift` | `@MainActor @Observable final class NotificationScheduler` (`:21`) | Owns timer-based reminder firing — per-event `Timer` invalidation + `UNUserNotificationCenter` delivery. Posts `.showFullScreenAlert` (`:332`) when a meeting alert fires |

## Cloud (`Infrastructure/Cloud/`)

| File | Type+line | Role |
|---|---|---|
| `CloudKitSyncMonitor.swift` | `CloudKitSyncMonitor` (`:23`) | Observable façade over `NSPersistentCloudKitContainer` — tracks iCloud account status, import/export/setup phases. Publishes `didFinishImport` for service reconciliation |
| `CloudServicesCoordinator.swift` | `CloudServicesCoordinator` (`:29`) | Single entry point unifying **two transports**: `NSPersistentCloudKitContainer` (backlog/events) and `NSUbiquitousKeyValueStore` (settings) behind one observable facade |
| `CloudSyncProtocols.swift` | `protocol CloudKitSyncMonitoring` (`:43`) | Read-only state + idempotent `start()`. Enables test fakes (`FakeCloudKitSyncMonitor`) without touching real containers |
| `CloudSyncService.swift` | `CloudSyncService` (`:19`) | Syncs settings and learning data via `NSUbiquitousKeyValueStore`. **Per-key merge semantics:** union-merge for energy check-ins, set-union for dismissed reminder IDs, last-writer-wins elsewhere |
| `FakeCloudServices.swift` | `FakeCloudKitSyncMonitor` (`:13`) | Mutable test double for `CloudKitSyncMonitoring` — tests and previews can drive every phase/error/idle transition |

## System (`Infrastructure/System/`)

| File | Type+line | Role |
|---|---|---|
| `EventCache.swift` | `actor EventCache` (`:8`) | **Actor** wrapping the offline calendar-event cache. SwiftData-backed. Save / load / clear / age-measure |
| `Keychain.swift` | `enum Keychain` (`:8`) | Wrapper around macOS Keychain Services API. Stores secrets as generic passwords scoped to the bundle ID. Used for user-provided DeepSeek API key (legacy keychain id `"anthropic-api-key"`) |
| `NetworkMonitor.swift` | `@MainActor class NetworkMonitor` (`:6`) | Observable wrapper around `NWPathMonitor`. Tracks connection **status and type** (wifi / cellular / ethernet) |
| `ResourceBundle.swift` | `enum ResourceBundle` | SPM-resource bundle accessor used by the skins loader to locate `BuiltInSkins/` JSONs |

## Application orchestrator helpers (Domain-pure + UI coordinators)

| File | Layer | Type+line | Role |
|---|---|---|---|
| `Application/Backlog/AutoDeferService.swift` | Application | `AutoDeferService` (`:40`) | Pushes overdue pending tasks forward to next workday morning via `BacklogService`. Idempotent within a day via `lastRunDate` tracking |
| `Presentation/Coordinators/BacklogInteractionCoordinator.swift` | Presentation | `BacklogInteractionCoordinator` (`:43`) | Cross-view coordinator for in-flight backlog-task drag state and ghost preview. Watchdog backup ends drag on mouse release |
| `Domain/Backlog/BacklogLogic.swift` | Domain | `enum BacklogLogic` (`:13`) | **Pure** namespace of deterministic helpers (filters, smart-sort, capacity math) over `[BacklogTask]`. Testable without SwiftUI |
| `Application/Energy/EnergyCheckInService.swift` | Application | `EnergyCheckInService` (`:11`) | Collects 2–3× daily energy ratings. Builds a personal hourly-multiplier curve that **replaces** the static Gaussian fallback in `EnergyCurveObjective` |
| `Application/Pomodoro/PomodoroHistoryService.swift` | Application | `@MainActor PomodoroHistoryService` (`:32`) | Persists completed/abandoned Pomodoro sessions in `UserDefaults` as JSON. Rolling window, **max 200 entries** |
| `Presentation/Coordinators/QuickCaptureBridge.swift` | Presentation | `QuickCaptureBridge` (`:17`) | Single-pass in-process buffer for ⇧↩ quick-capture prefill from `AppDelegate` to `MenuBarView`. Write-once / consume-once semantics |
| `Domain/Recurrence/RecurrenceEngine.swift` | Domain | `enum RecurrenceEngine` (`:21`) | Derives next occurrence date for a recurring `BacklogTask` from its free-form `recurrenceTag` via case-insensitive keyword matching |
| `Domain/Recurrence/RecurrenceExpander.swift` | Domain | `enum RecurrenceExpander` (`:5`) | Expands recurring `CalendarEvent`s into occurrences within a window. Full RFC 5545 frequency support. Exclusion lists + per-frequency safety limits |
| `Presentation/Coordinators/SlotPreviewCache.swift` | Presentation | `SlotPreviewCache` (`:15`) | Memoizes "where would a task of duration D land?" — keyed on duration + events fingerprint. Invalidates on calendar mutation. Imports `Observation` (not `SwiftUI`) so the service layer stays UI-framework-free |
| `Domain/Calendar/TimelineSlotRanker.swift` | Domain | `enum TimelineSlotRanker` (`:16`) | **Pure.** Scores and ranks backlog tasks for a timeline slot by five dimensions: urgency, fit, context-match, period preference, recency |
| `Application/Undo/UndoService.swift` | Application | `@MainActor @Observable UndoService` (`:13`) | Centralized undo. `push(label, duration: 5, undo:)` shows a toast for N seconds; executes closure on undo or auto-dismiss. See [`../concepts/undo.md`](../concepts/undo.md) |

## Conventions

- Services emit cross-cutting changes via `NotificationCenter` — see [`../concepts/notifications-bus.md`](../concepts/notifications-bus.md). Direct property reads use `@Observable` for tight UI binding.
- Construction is centralized in `AppContainer`. Do not `init()` a service in a view or another service ad-hoc; ask `AppContainer`.
- Heavy work (GA runs, network) is dispatched off the main actor; results are written back on `@MainActor`.
- Pure namespaces (`BacklogLogic`, `TimelineSlotRanker`, `RecurrenceEngine`, `RecurrenceExpander`, `UpsertReconciler`, `Keychain`) are `enum`s. The pattern intentionally prevents instantiation when only static functions matter.
