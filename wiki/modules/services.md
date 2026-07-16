# Module: Services

> **Kind:** module
> **Sources:** Bubo/Application/, Bubo/Infrastructure/Apple/, Bubo/Infrastructure/Cloud/, Bubo/Infrastructure/Notifications/, Bubo/Infrastructure/Persistence/, Bubo/Infrastructure/Bundle/, Bubo/Presentation/Coordinators/, Sources/Domain/
> **Last ingest:** 2026-07-15 (rev: PR #590 — `OptimizerService` row documents the new per-day working-hours overrides (`DayWorkingHours`, `workingHoursOverrides`, `workingHours(on:)`, `setWorkingHours(on:start:end:)`); prior rev: `Infrastructure/System/` section retired — files now live in `Security/`, `Network/`, `Cache/`, `Bundle/` (four peers); line refs resynced for `BacklogService` (`:11`), `EventCache` (`:9`), `ResourceBundle.safeModule` (`:6`), `AutoDeferService` (`:41`), `BacklogLogic` (`:14`), `EnergyCheckInService` (`:12`), `PomodoroHistoryService` (`:33`), `RecurrenceEngine` (`:15`), `RecurrenceExpander` (`:6`); added `BacklogLogic+ShadowSlots.swift` row)
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
├── Apple/                      # EventKit + Reminders wrappers, protocol-based sources,
│   │                           #   plus EventKitSyncCoordinator (timer/cascade owner)
│   └── Fakes/                  # Fake{Calendar,Reminders}EventSource test doubles
├── Bundle/                     # ResourceBundle (Bundle.safeModule)
├── Cache/                      # EventCache (actor) — offline calendar-event cache
├── Cloud/                      # CloudKit monitor, services coordinator, sync protocols + service
│   └── Fakes/                  # FakeCloudServices test double
├── Network/                    # NetworkMonitor (NWPathMonitor wrapper)
├── Notifications/              # NotificationScheduler — per-event Timer + UN delivery + alert bridge
├── Persistence/                # SwiftData stores + @Model classes + reconciler + in-memory fakes
└── Security/                   # Keychain (macOS Keychain Services wrapper)
Domain/                         # 4 pure-namespace services migrated here: BacklogLogic,
                                # RecurrenceEngine, RecurrenceExpander, TimelineSlotRanker
Presentation/Coordinators/      # 3 UI-state coordinators: BacklogInteractionCoordinator,
                                # QuickCaptureBridge, SlotPreviewCache
```

Note: there is no `Infrastructure/Reminders/` anymore. The former contents were split by concern: `NotificationScheduler` (local user notifications + full-screen alert bridge) lives in `Infrastructure/Notifications/`, and `EventKitSyncCoordinator` (EventKit sync timer + cascade) joined the rest of the EventKit code in `Infrastructure/Apple/`. The Apple-Reminders bridge service (`RemindersSyncService.swift`) still lives in `Application/Reminders/`.

## Orchestrators (the public surface)

| Service | Owns | Read by |
|---|---|---|
| `ReminderService` (`ReminderService.swift:29`) | `upcomingEvents`, `localEvents`, plus four sub-services: `EventKitSyncCoordinator`, `NotificationScheduler`, three persistence stores | `MenuBarView`, `OptimizerService`, `AppDelegate` |
| `BacklogService` (`BacklogService.swift:11`) | `tasks`, `BacklogTaskStore`. Posts `.taskAdded` / `.taskUpdated` / `.taskRemoved` / `.taskCompleted` / `.taskScheduleChanged`. Reconciles after CloudKit import via monotonic field handling. Stale-task age threshold lives in one place: `staleTaskThresholdDays = 14` + `staleTaskCutoff` helper (shared by `staleTasks` and `dropStaleTasks`). Mutation surface (add/update/remove/complete/freeze/schedule/reorder + silent-* helpers used by `RemindersSyncService` to dodge sync echoes) lives in `BacklogService+Mutations.swift` (`completeTask` at `:93` calls `RecurrenceEngine.nextOccurrence` at `:111` for recurring rows) | `BacklogScreenModel` (`BacklogScreenModel.swift:19`), `OptimizerService`, `EditTaskView` |
| `OptimizerService` (`OptimizerService.swift`) | `BuboOptimizer`, `IntentLearner`, `scenarios`, `shadowProposal`. After the 2026-05-12 split, the service core is 320 L and the rest lives in five sibling files: `+ShadowProposals` (background `previewRequest`, `clearShadowProposal`, `switchToAppliedScenario`); `+Persistence` (`saveSettings`/`loadSettings`/`SavedSettings`); `+Settings` (persisted optimizer toggles + CloudKit cross-device sync); `+Execute` (`executeRequest` pipeline + `instantReflow`/`executeDryRun`/`previewScenarios`/`applyPreviewedScenario`/`runWeekMockSimulator`); `+ApplyScenario` (`applyScenario`/`rejectScenario` commit paths). `private(set)` was dropped on `isOptimizing`/`error`/`lastSnapshot`/`lastAppliedRequest`/`selectedScenarioIndex`/`lastOptimizationDate` so the sibling files can mutate run state. **Per-day working-hours overrides** (PR #590): `workingHoursOverrides: [String: DayWorkingHours]` (`OptimizerService.swift:64`, `DayWorkingHours` struct `:50`), keyed by `Self.dayKey(for:)` (`yyyy-MM-dd`, `OptimizerService+Settings.swift:84`). `workingHours(on:)` (`+Settings.swift:98`) resolves a day's override or falls back to the global `workingHoursStart...workingHoursEnd`; `setWorkingHours(on:start:end:)` (`+Settings.swift:111`) writes one day's override (clamped, auto-removed when it matches the default). Persistence in `+Persistence.swift` (`saveWorkingHoursOverrides`/`loadWorkingHoursOverrides`, `:62`/`:70`) prunes past-day entries at load. The GA/intents pipeline still plans against the global default only — per-day windows aren't threaded through the compiler yet. | `MenuBarView` (ghost previews), `OptimizerTabView`, `CommandPalette`, `MenuBarView+DayGroup` (inline boundary handles), `BacklogScreenModel`/`MenuBarView+MainContent` (today's capacity verdicts) |
| `RemindersSyncService` (`RemindersSyncService.swift:57`) | Reminders→Bubo import path: sync timer, external-edit merging, dismissal tracking. The inverse Bubo→Reminders writeback (completion/export/edit/schedule/remove + alarm-settings sweep + linkage helpers) lives in `RemindersSyncService+Writeback.swift`. Posts `didImportTasks` | `AppDelegate`, `RemindersTabView`, `AppleRemindersTabView` |
| `AgentService` (`AgentService.swift:24`) | **DeepSeek** client (OpenAI-compatible) + rate-limit window. Two modes: `.builtIn` (via Bubo Cloudflare-Worker proxy) and `.ownKey` (direct `api.deepseek.com`, key in Keychain under historical id `"anthropic-api-key"` at `:66`). Direct endpoint `:100` (`api.deepseek.com/chat/completions`), model `:132` (`"deepseek-chat"`). The OpenAI-compatible request/response types, `RequestToolSchema` JSON schema, and `AgentError` cases were lifted to sibling files (`AgentAPITypes.swift`, `AgentRecipeToolSchema.swift`, `AgentError.swift`) so the service file is just the @Observable surface | `AssistantTabView`, `CommandPalette` |

## Apple (`Infrastructure/Apple/`)

| File | Type+line | Role |
|---|---|---|
| `AppleCalendarService.swift` | `class AppleCalendarService` (`:13`) | EventKit calendar access via a shared `EKEventStore`. Observes external changes. Posts `calendarDataChanged` and `authorizationDidChange` |
| `AppleRemindersService.swift` | `@MainActor @Observable final class AppleRemindersService` (`:15`) | Read/write access to Apple Reminders via EventKit; **reuses the shared `EKEventStore`**. Posts `remindersDataChanged` and `authorizationDidChange`. 423 L of authorization + list / fetch / write / schedule-update / mutate; the EKReminder↔BacklogTask conversion helpers moved to `AppleRemindersService+Convert.swift` on 2026-05-13 |
| `AppleRemindersService+Convert.swift` | `@MainActor extension AppleRemindersService` (`:18`) | Pure conversion helpers extracted 2026-05-13 (274 L): `toBacklogTask(_:defaultDuration:)`, priority mapping (`appleRemindersPriority(from:)` ↔ `buboPriority(fromAppleReminders:)`), `dueDateComponents(from:)`, notes / URL / subtasks / tags codec (`composeNotes`, `extractURL`, `extractAttachments` + private `parseTagsLine` / `parseChecklistLine` + the three sentinel constants). No instance-state access |
| `CalendarEventSource.swift` | `protocol CalendarEventSource` (`:18`) | Test-seam abstraction over `AppleCalendarService` |
| `EventKitSyncCoordinator.swift` | `@MainActor @Observable final class EventKitSyncCoordinator` (`:24`) | Owns EventKit sync timer + post-sync cascade + in-flight refresh task + disk-cache write-back. Driven by `ReminderService` |
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

## Notifications (`Infrastructure/Notifications/`)

| File | Type+line | Role |
|---|---|---|
| `NotificationScheduler.swift` | `@MainActor @Observable final class NotificationScheduler` (`:21`) | Owns timer-based reminder firing — per-event `Timer` invalidation + `UNUserNotificationCenter` delivery. Posts `.showFullScreenAlert` (`:332`) when a meeting alert fires |

`EventKitSyncCoordinator.swift` was relocated to `Infrastructure/Apple/` — see the Apple section above for the row, since it is EventKit code and belongs next to `AppleCalendarService` and `AppleRemindersService`.

## Cloud (`Infrastructure/Cloud/`)

| File | Type+line | Role |
|---|---|---|
| `CloudKitSyncMonitor.swift` | `CloudKitSyncMonitor` (`:23`) | Observable façade over `NSPersistentCloudKitContainer` — tracks iCloud account status, import/export/setup phases. Publishes `didFinishImport` for service reconciliation |
| `CloudServicesCoordinator.swift` | `CloudServicesCoordinator` (`:29`) | Single entry point unifying **two transports**: `NSPersistentCloudKitContainer` (backlog/events) and `NSUbiquitousKeyValueStore` (settings) behind one observable facade |
| `CloudSyncProtocols.swift` | `protocol CloudKitSyncMonitoring` (`:43`) | Read-only state + idempotent `start()`. Enables test fakes (`FakeCloudKitSyncMonitor`) without touching real containers |
| `CloudSyncService.swift` | `CloudSyncService` (`:19`) | Syncs settings and learning data via `NSUbiquitousKeyValueStore`. **Per-key merge semantics:** union-merge for energy check-ins, set-union for dismissed reminder IDs, last-writer-wins elsewhere |
| `FakeCloudServices.swift` | `FakeCloudKitSyncMonitor` (`:13`) | Mutable test double for `CloudKitSyncMonitoring` — tests and previews can drive every phase/error/idle transition |

## Platform glue (split across `Infrastructure/{Cache,Security,Network,Bundle}/`)

| File | Type+line | Role |
|---|---|---|
| `Cache/EventCache.swift` | `actor EventCache` (`:9`) | **Actor** wrapping the offline calendar-event cache. SwiftData-backed. Save / load / clear / age-measure |
| `Security/Keychain.swift` | `enum Keychain` (`:8`) | Wrapper around macOS Keychain Services API. Stores secrets as generic passwords scoped to the bundle ID. Used for user-provided DeepSeek API key (legacy keychain id `"anthropic-api-key"`) |
| `Network/NetworkMonitor.swift` | `@MainActor class NetworkMonitor` (`:6`) | Observable wrapper around `NWPathMonitor`. Tracks connection **status and type** (wifi / cellular / ethernet) |
| `Bundle/ResourceBundle.swift` | `extension Bundle` with `Bundle.safeModule` (`:6`) | SPM-resource bundle accessor used by the skins loader to locate `BuiltInSkins/` JSONs. Returns `nil` instead of `fatalError` when `Bubo_Bubo.bundle` is missing |

## Application orchestrator helpers (Domain-pure + UI coordinators)

| File | Layer | Type+line | Role |
|---|---|---|---|
| `Application/Backlog/AutoDeferService.swift` | Application | `AutoDeferService` (`:41`) | Pushes overdue pending tasks forward to next workday morning via `BacklogService`. Idempotent within a day via `lastRunDate` tracking |
| `Application/Backlog/BacklogLogic+ShadowSlots.swift` | Application | `extension BacklogLogic` (43 L) | Shadow-slot preview helpers — derives the "where would this task land?" preview state from a task list + current cursor without committing to a write |
| `Presentation/Coordinators/BacklogInteractionCoordinator.swift` | Presentation | `BacklogInteractionCoordinator` (`:43`) | Cross-view coordinator for in-flight backlog-task drag state and ghost preview. Watchdog backup ends drag on mouse release |
| `Domain/Backlog/BacklogLogic.swift` | Domain | `enum BacklogLogic` (`:14`) | **Pure** namespace of deterministic helpers (filters, smart-sort, capacity math) over `[BacklogTask]`. Testable without SwiftUI |
| `Application/Energy/EnergyCheckInService.swift` | Application | `EnergyCheckInService` (`:12`) | Collects 2–3× daily energy ratings. Builds a personal hourly-multiplier curve that **replaces** the static Gaussian fallback in `EnergyCurveObjective` |
| `Application/Pomodoro/PomodoroHistoryService.swift` | Application | `@MainActor PomodoroHistoryService` (`:33`) | Persists completed/abandoned Pomodoro sessions in `UserDefaults` as JSON. Rolling window, **max 200 entries** |
| `Presentation/State/QuickCaptureBridge.swift` | Presentation | `QuickCaptureBridge` (`:17`) | Single-pass in-process buffer for ⇧↩ quick-capture prefill from `AppDelegate` to `MenuBarView`. Write-once / consume-once semantics |
| `Domain/Recurrence/RecurrenceEngine.swift` | Domain | `enum RecurrenceEngine` (`:15`) | Derives next occurrence date for a recurring `BacklogTask` from its free-form `recurrenceTag` via case-insensitive keyword matching |
| `Domain/Recurrence/RecurrenceExpander.swift` | Domain | `enum RecurrenceExpander` (`:6`) | Expands recurring `CalendarEvent`s into occurrences within a window. Full RFC 5545 frequency support. Exclusion lists + per-frequency safety limits |
| `Presentation/State/SlotPreviewCache.swift` | Presentation | `SlotPreviewCache` (`:15`) | Memoizes "where would a task of duration D land?" — keyed on duration + events fingerprint. Invalidates on calendar mutation. Imports `Observation` (not `SwiftUI`) so the service layer stays UI-framework-free |
| `Domain/Calendar/TimelineSlotRanker.swift` | Domain | `enum TimelineSlotRanker` (`:16`) | **Pure.** Scores and ranks backlog tasks for a timeline slot by five dimensions: urgency, fit, context-match, period preference, recency |
| `Application/Undo/UndoService.swift` | Application | `@MainActor @Observable UndoService` (`:13`) | Centralized undo. `push(label, duration: 5, undo:)` shows a toast for N seconds; executes closure on undo or auto-dismiss. See [`../concepts/undo.md`](../concepts/undo.md) |

## Conventions

- Services emit cross-cutting changes via `NotificationCenter` — see [`../concepts/notifications-bus.md`](../concepts/notifications-bus.md). Direct property reads use `@Observable` for tight UI binding.
- Construction is centralized in `AppContainer`. Do not `init()` a service in a view or another service ad-hoc; ask `AppContainer`.
- Heavy work (GA runs, network) is dispatched off the main actor; results are written back on `@MainActor`.
- Pure namespaces (`BacklogLogic`, `TimelineSlotRanker`, `RecurrenceEngine`, `RecurrenceExpander`, `UpsertReconciler`, `Keychain`) are `enum`s. The pattern intentionally prevents instantiation when only static functions matter.
