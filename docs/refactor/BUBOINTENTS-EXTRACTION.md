# BuboIntents SPM Target Extraction — Execution Plan

> **Status:** Pending. Requires a working Swift toolchain (`swift build`)
> to execute incrementally. Each step below MUST be followed by
> `swift build` before proceeding. Estimated effort with build env: 4-6h.

## 1. Why

`Bubo/Application/Intents/` is a self-contained reasoning subsystem
(graph, rules, compiler, suggestion/trigger engines, LLM bridge) that
only imports `BuboDomain`, `BuboOptimizer`, `Foundation`,
`UserNotifications`, `os`. Its 19 files / ~6000 LoC currently sit
inside the macOS app target because they depend on app-level services
(`ReminderService`, `BacklogService`, `OptimizerService`,
`CloudSyncService`, `EnergyCheckInService`, `IntentLearner`,
`PomodoroHistoryService`).

The dependency direction is wrong: intents are a layer the app
*orchestrates*, not the other way around. Extracting to a separate SPM
target named `BuboIntents` (sibling of `BuboDomain` / `BuboOptimizer`)
makes:

- Pure intent reasoning testable without the app target compiling.
- The set of services intents depends on explicit and reviewable.
- Other downstream consumers (CLI tools, server, scripts) able to
  reuse the reasoning without dragging EventKit/CloudKit/AppKit.

## 2. Target structure after extraction

```
Sources/BuboIntents/
├── Protocols/
│   └── IntentsServices.swift    (new — 6 protocols, 1 enum)
├── Models/
│   └── IntentExecutionRecord.swift  (extracted from IntentLearner)
├── Bridges/      (1 file)
├── Compiler/     (5 files)
├── Engines/      (3 files)
├── Graph/        (5 files)
├── Rules/        (3 files)
├── IntentPresets.swift
└── ScheduleIntent.swift

Package.swift target additions:
  .target(name: "BuboIntents", dependencies: ["BuboDomain", "BuboOptimizer"])
  Bubo executableTarget gains "BuboIntents" dep.
  BuboTests gains "BuboIntents" dep.
```

## 3. Protocols to define (in `Sources/BuboIntents/Protocols/IntentsServices.swift`)

All `@MainActor` except `IntentsCloudSync`.

### `IntentsReminderService`

```swift
@MainActor public protocol IntentsReminderService: AnyObject {
    var allEvents: [CalendarEvent] { get }
    var localEvents: [CalendarEvent] { get }
    func addLocalEvent(_ event: CalendarEvent)
    func removeLocalEvent(id: String)
}
```

Used at:
- `IntentCompiler.swift:109,111`, `IntentCompiler+Apply.swift:420,444,604`,
  `IntentCompiler+EventCollection.swift:295`,
  `IntentCompiler+Preferences.swift:60`, `SuggestionEngine.swift:117`,
  `QuickActionRanker.swift:124`, `ScheduleIntent.swift:654`

Concrete: `ReminderService` (`Bubo/Application/Reminders/ReminderService.swift`).
`addLocalEvent` / `removeLocalEvent` are used inside `OptimizerService` body
(see §5 — widening), not by Intents code directly.

### `IntentsBacklogService`

```swift
@MainActor public protocol IntentsBacklogService: AnyObject {
    var tasks: [BacklogTask] { get }
    var pending: [BacklogTask] { get }
    var schedulable: [BacklogTask] { get }
    var overdue: [BacklogTask] { get }
    func urgent(withinDays days: Int) -> [BacklogTask]
}
```

Plus a separate non-actor-isolated enum for notification names:

```swift
public enum IntentsBacklogNotifications {
    public static let taskAdded = Notification.Name("BuboBacklogTaskAdded")
    public static let taskRemoved = Notification.Name("BuboBacklogTaskRemoved")
    public static let taskUpdated = Notification.Name("BuboBacklogTaskUpdated")
    public static let taskCompleted = Notification.Name("BuboBacklogTaskCompleted")
    public static let taskScheduleChanged = Notification.Name("BuboBacklogTaskScheduleChanged")
}
```

Intents code currently reads these names as `BacklogService.taskAdded` etc.
(`SuggestionEngine.swift:59-63`). Replace with
`IntentsBacklogNotifications.taskAdded` etc.

Concrete: `BacklogService` (`Bubo/Application/Backlog/BacklogService.swift`).

### `IntentsOptimizerService`

```swift
@MainActor public protocol IntentsOptimizerService: AnyObject {
    var scenarios: [ScheduleScenario] { get }
    var subgraphRegistry: SubgraphRegistry? { get }
    func executeRequest(
        _ request: OptimizationRequest,
        reminderService: any IntentsReminderService
    ) async -> OptimizationResult
    func applyScenario(
        at index: Int,
        to reminderService: any IntentsReminderService
    )
}
```

`SubgraphRegistry` is currently defined inside
`Bubo/Application/Intents/Graph/IntentGraphAdvanced.swift`. After the
move it lives in BuboIntents; `OptimizerService.swift` will need to
`import BuboIntents` to keep its `private(set) var subgraphRegistry:
SubgraphRegistry?` field — this is the reason for the Bubo→BuboIntents
dep direction (no cycle).

### `IntentsCloudSync`

```swift
public protocol IntentsCloudSync: Sendable {
    func push(_ key: String)
}
```

Used at `IntentGraphAdvanced.swift:181`:
`CloudSyncService.shared.push(persistenceKey)`.

Concrete: `CloudSyncService` (`Bubo/Infrastructure/Cloud/CloudSyncService.swift`).
The singleton `.shared` access is the trickiest call site — replace
with constructor injection (`subgraphRegistry` gets a
`cloudSync: any IntentsCloudSync` parameter) or with a
type-erased closure (`onPersistenceChanged: @Sendable (String) -> Void`).
Constructor injection is preferred.

### `IntentsEnergyService`

```swift
@MainActor public protocol IntentsEnergyService: AnyObject {
    var hasEnoughData: Bool { get }
    func predictedCurve(dayOfWeek: Int, meetingCount: Int, defaultPeakHour: Int) -> [Double]
}
```

Used at `IntentCompiler+Preferences.swift:55,63`.

Concrete: `EnergyCheckInService` (`Bubo/Application/Energy/EnergyCheckInService.swift`).

### `IntentsLearner` + `IntentExecutionRecord`

Extract the nested `IntentLearner.IntentExecution` struct into a public
top-level type in `Sources/BuboIntents/Models/IntentExecutionRecord.swift`:

```swift
public struct IntentExecutionRecord: Codable, Sendable {
    public let intents: [ScheduleIntent]
    public let name: String?
    public let outcome: Outcome
    public let timestamp: Date
    public let hour: Int
    public let dayOfWeek: Int

    public enum Outcome: String, Codable, Sendable {
        case accepted, rejected, modified
    }
}
```

The protocol:

```swift
@MainActor public protocol IntentsLearner: AnyObject {
    var intentFrequency: [String: Int] { get }
    var history: [IntentExecutionRecord] { get }
}
```

Used at `QuickActionRanker.swift:172,173,251,277,278`.

Concrete: `IntentLearner` (`Bubo/Application/Learning/IntentLearner.swift`).
After the move, `IntentLearner` keeps its `history: [IntentExecutionRecord]`
storage directly — no mapping needed. `recordExecution(_:outcome:)`
internally constructs an `IntentExecutionRecord`. Its references to
`CloudSyncService.shared.push(...)` stay (they're internal to
`IntentLearner`, unrelated to the Intents target).

### `IntentsPomodoroHistory`

Marker protocol — `PomodoroConfigResolver` holds an optional reference
but doesn't invoke methods through it today (audit confirmed). A
`final class PomodoroHistoryService` reference passed as parameter
becomes `(any IntentsPomodoroHistory)?`. Future work can widen the
protocol when actual surface emerges.

```swift
@MainActor public protocol IntentsPomodoroHistory: AnyObject {}
```

## 4. Public surface checklist

Every top-level type below (currently `internal`) needs `public`. Plus
each externally-referenced member (init / let / var / func). Where this
plan says "expose members" assume the auditor's list in
`AGENTS.md`-style ingest determines exact members.

### Top-level types (29) requiring `public`

| File | Type |
|---|---|
| `ScheduleIntent.swift` | `enum ScheduleIntent` (`indirect`), `enum TaskOrderStrategy`, `enum HalfDayMode`, `enum IntentCondition`, `enum IntentCardinalityKey`, `enum IntentCategory`, `struct OptimizationRequest` |
| `IntentPresets.swift` | `struct IntentPresets` |
| `Bridges/LLMIntentBridge.swift` | `struct LLMIntentBridge`, nested `struct ParseError` |
| `Graph/IntentGraph.swift` | `struct IntentGraph`, nested `Node`, `Edge`, `EdgeKind`, `Phase`, `Condition` |
| `Graph/IntentGraphAdvanced.swift` | `struct Subgraph`, `final class SubgraphRegistry`, `enum PortType`, `struct Port` (+ nested `Direction`), `struct ParallelBranch`, `struct ParallelSplit` (+ nested `MergeStrategy`), `struct PipelineVariable` (+ nested `ValueType`), `enum PipelineValue` |
| `Compiler/IntentCompiler.swift` | `struct IntentCompiler` |
| `Compiler/IntentCompiler+Apply.swift` | nested `ResolvedConfig`, `EventTransform` (extensions on `IntentCompiler`) |
| `Engines/SuggestionEngine.swift` | `final class SuggestionEngine` (+ nested `Suggestion`, `Signal`, `ContextLayer`) |
| `Engines/TriggerEngine.swift` | `final class TriggerEngine` |
| `Engines/QuickActionRanker.swift` | `struct QuickActionRanker` (+ nested `ScoredAction`, `ContextInputs`), `struct QuickActionCandidate`, `enum ContextSignal` |
| `Rules/IntentConflictDetector.swift` | `enum IntentConflictDetector` (+ nested `Conflict` + `Severity`) |
| `Rules/BacklogTaskCohesion.swift` | `enum BacklogTaskCohesion` (+ nested `Weights`) |
| `Rules/PomodoroConfigResolver.swift` | `enum PomodoroConfigResolver`, `struct PomodoroResolverTuning`, `struct PomodoroResolveSignals` |

### Members to mark `public`

For each top-level type above: every `init`, `let`, `var`, `func`,
`static let/var/func` that is referenced from outside
`Sources/BuboIntents/`. The audit in
[external-symbols.md](#) (also produced in the conversation that
seeded this plan) enumerates these. As a safety default, mark every
non-`private`/`fileprivate` member `public`, then tighten back to
`internal` for things that fail no callsite test (i.e. that no
external code uses).

## 5. Signature changes outside BuboIntents

### `OptimizerService.executeRequest`

`Bubo/Application/Optimizer/OptimizerService+Execute.swift:17-20`

Before:
```swift
func executeRequest(
    _ request: OptimizationRequest,
    reminderService: ReminderService
) async -> OptimizationResult
```

After:
```swift
func executeRequest(
    _ request: OptimizationRequest,
    reminderService: any IntentsReminderService
) async -> OptimizationResult
```

Body uses only `reminderService.allEvents`, `.localEvents`,
`.removeLocalEvent(id:)`, `.addLocalEvent(_:)` — all on the protocol,
no body changes needed.

External callers (7 known sites — all already pass a concrete
`ReminderService`, which conforms via extension):

- `Bubo/Presentation/Views/Event/AddEventView+FindBestTime.swift:86,105`
- `Bubo/Presentation/Views/CommandPalette/CommandPalette+Actions.swift:41`
- `Bubo/Presentation/Views/MenuBar/MenuBarView+EventRow.swift:125`
- `Bubo/Presentation/Views/MenuBar/MenuBarView+EventActions.swift:66`

### `OptimizerService.applyScenario`

`Bubo/Application/Optimizer/OptimizerService+ApplyScenario.swift:14-19`

Before:
```swift
func applyScenario(
    at index: Int,
    to reminderService: ReminderService,
    titleOverride: String? = nil,
    colorOverride: EventColorTag? = nil
)
```

After:
```swift
func applyScenario(
    at index: Int,
    to reminderService: any IntentsReminderService,
    titleOverride: String? = nil,
    colorOverride: EventColorTag? = nil
)
```

External callers (2 sites): `CommandPalette+Actions.swift:51`,
`MenuBarView+EventActions.swift:68`.

### `OptimizerService.intentLearner` access type

`Bubo/Application/Optimizer/OptimizerService.swift:16` declares
`let intentLearner = IntentLearner()`. Since `IntentLearner` stays in
the Bubo target, no change to the field — but consumers
(`SmartActionsBar.swift:131`, `CommandPalette.swift:179`) pass it to
`QuickActionRanker` which expects `any IntentsLearner`. So
`IntentLearner: IntentsLearner` extension is enough.

## 6. Conformance extensions to add in Bubo target

New file: `Bubo/Composition/IntentsConformances.swift`:

```swift
import Foundation
import BuboDomain
import BuboIntents

extension ReminderService: IntentsReminderService {}
extension BacklogService: IntentsBacklogService {}
extension OptimizerService: IntentsOptimizerService {}
extension CloudSyncService: IntentsCloudSync {}
extension EnergyCheckInService: IntentsEnergyService {}
extension IntentLearner: IntentsLearner {}
extension PomodoroHistoryService: IntentsPomodoroHistory {}
```

Each conformance is `extension X: P {}` with no body — the concrete
methods already satisfy the protocol.

EXCEPTION — `BacklogService`: the notification name constants
(`taskAdded`, `taskRemoved`, …) are kept as `static let` on
`BacklogService` for backward compat with non-Intents callers. The
`IntentsBacklogNotifications` enum (in BuboIntents) re-exposes the
same `Notification.Name` strings, so Intents code uses
`IntentsBacklogNotifications.taskAdded` and the rest of the app uses
`BacklogService.taskAdded` — both yield identical names.

## 7. Inside-Intents code edits

Each Intents file holding a concrete service reference replaces it
with the protocol:

| File | Field change |
|---|---|
| `Bridges/LLMIntentBridge.swift:19` | `let reminderService: ReminderService` → `let reminderService: any IntentsReminderService` |
| `Compiler/IntentCompiler.swift:26-27` | `let reminderService: ReminderService` → `any IntentsReminderService`; `let backlogService: BacklogService` → `any IntentsBacklogService` |
| `Compiler/IntentCompiler.swift:33` | `var pomodoroHistory: PomodoroHistoryService?` → `(any IntentsPomodoroHistory)?` |
| `Compiler/IntentCompiler+Preferences.swift:55,63` | `energyService` typed as `any IntentsEnergyService` |
| `Engines/SuggestionEngine.swift:30-31, 45` | `reminderService` + `backlogService` typed as protocols |
| `Engines/SuggestionEngine.swift:59-63` | `BacklogService.taskAdded` → `IntentsBacklogNotifications.taskAdded` (5 sites) |
| `Engines/TriggerEngine.swift:21,28` | `optimizerService: any IntentsOptimizerService`, `reminderService: any IntentsReminderService` |
| `Engines/QuickActionRanker.swift:26-28` | three fields typed as protocols, `intentLearner: any IntentsLearner` |
| `Graph/IntentGraphAdvanced.swift:181` | `CloudSyncService.shared.push(...)` → use injected `cloudSync: any IntentsCloudSync` parameter |

`SubgraphRegistry`'s `init` and `push(...)` paths gain a
`cloudSync: any IntentsCloudSync` constructor parameter; the call
to `.push(persistenceKey)` becomes `cloudSync.push(persistenceKey)`.
`OptimizerService.swift:280` creates the registry — pass
`CloudSyncService.shared` there.

## 8. AppContainer wiring (only verify, no logic change expected)

`Bubo/Composition/App/AppContainer.swift` already injects concrete
services into every Intents consumer. After §6 (extension conformances),
all those concrete refs satisfy the new protocol-typed parameters
implicitly — no code changes expected. Verify with `swift build`.

## 9. Test updates

Test files under `Tests/BuboTests/Intents/` and
`Tests/BuboTests/Integration/` use concrete service types. Each
test that constructs an Intents type with a fake service needs
either:

- The fake to conform to the new protocol (`extension FakeReminderService:
  IntentsReminderService {}` etc.), or
- The Intents type init to accept `any IntentsXxxService` (already
  changed in §7).

Tests already in `Tests/BuboTests/Support/` provide fakes — most
should pick up the conformance for free.

Add `@testable import BuboIntents` to each test file that imports
Intents types.

## 10. Wiki updates

After build verification:
- `wiki/index.md` — add entry for `modules/intents.md`.
- `wiki/modules/intents.md` — new page documenting the BuboIntents
  target (frontmatter `Sources: Sources/BuboIntents/`).
- `wiki/architecture/overview.md` — update target diagram.
- `wiki/architecture/layered-structure.md` — add the new target as a
  layer between BuboOptimizer and Bubo.
- `wiki/log.md` — append refactor entry.

## 11. Execution order

1. **Setup (no functional change yet).** Create the Protocols/ and
   Models/IntentExecutionRecord.swift files. `swift build` — should
   build (new files only, used by nothing).
2. **Conformances.** Add `Bubo/Composition/IntentsConformances.swift`
   with empty-body extensions. `swift build` — should build.
3. **Widen OptimizerService.** Change `executeRequest` and
   `applyScenario` to take `any IntentsReminderService`. `swift build`
   — should build (existing callers pass concrete `ReminderService`
   which now conforms via §2).
4. **Move IntentExecution.** Replace `IntentLearner.IntentExecution`
   nested type usages with `IntentExecutionRecord`. `swift build`.
5. **Move files.** `git mv` Intents subdirs from `Bubo/Application/`
   to `Sources/BuboIntents/`. Update Package.swift to add the new
   target. `swift build` — will fail with "X is internal, cannot be
   referenced" across many sites.
6. **Bulk public.** Run sed pass: add `public` to every type and
   member listed in §4. Re-run `swift build`, iterate until clean.
7. **Swap concrete refs in Intents files.** Apply §7 edits. `swift build`.
8. **Tests.** Move `Tests/BuboTests/Intents/` mocks/fakes to conform
   to protocols. Add `@testable import BuboIntents` where needed.
   `swift test`.
9. **Wiki.** Per §10.

## 12. Audit data (don't re-run on each session)

External symbols referenced by Intents from OUTSIDE the directory,
grouped by service:

(See full audit table at the top of this plan — preserved here for
self-containment.)

### ReminderService callsites

| Property/Method | Call site |
|---|---|
| `.allEvents` | IntentCompiler.swift:109, 111; IntentCompiler+Apply.swift:420, 444, 604; IntentCompiler+Preferences.swift:60; SuggestionEngine.swift:117; QuickActionRanker.swift:124 |
| `.localEvents` | IntentCompiler+EventCollection.swift:295 |
| (parameter only) | ScheduleIntent.swift:654 |

### BacklogService callsites

| Property/Method | Call site |
|---|---|
| `.schedulable` | IntentCompiler+EventCollection.swift:94; IntentCompiler+Apply.swift:534, 626; SuggestionEngine.swift via context; QuickActionRanker.swift:133, 299 |
| `.pending` | IntentCompiler+Apply.swift:438; SuggestionEngine.swift:132 |
| `.tasks` | IntentCompiler+Apply.swift:427 |
| `.urgent(withinDays:2)` | SuggestionEngine.swift:133; QuickActionRanker.swift:132 |
| `.overdue` | SuggestionEngine.swift:134; QuickActionRanker.swift:131, 356 |
| `.taskAdded` etc. (`Notification.Name`) | SuggestionEngine.swift:59-63 |

### OptimizerService callsites

| Property/Method | Call site |
|---|---|
| `.executeRequest(_:reminderService:)` | LLMIntentBridge.swift:41; TriggerEngine.swift:208 |
| `.subgraphRegistry` | TriggerEngine.swift:37, 186 |
| `.scenarios` | TriggerEngine.swift:212 |
| `.applyScenario(at:to:)` | TriggerEngine.swift:213 |

### CloudSyncService callsites

| Property/Method | Call site |
|---|---|
| `.shared.push(_:)` | IntentGraphAdvanced.swift:181 |

### EnergyCheckInService callsites

| Property/Method | Call site |
|---|---|
| `.hasEnoughData` | IntentCompiler+Preferences.swift:55 |
| `.predictedCurve(dayOfWeek:meetingCount:defaultPeakHour:)` | IntentCompiler+Preferences.swift:63 |

### IntentLearner callsites

| Property/Method | Call site |
|---|---|
| `.intentFrequency` | QuickActionRanker.swift:172, 277, 278 |
| `.history` (filter on `.outcome`, `.hour`, `.dayOfWeek`, `.intents`, `.name`) | QuickActionRanker.swift:173, 251 |
