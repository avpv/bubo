# Wiki log

Append-only chronological record of wiki operations. Newest at the bottom. See `../AGENTS.md` §4.4 for entry format.

---

## [2026-05-11] bootstrap | Initial wiki from full Bubo/ sweep

- **Trigger:** human request — "create automatic LLM wiki per Karpathy gist"
- **Touched:** entire `wiki/` tree, `AGENTS.md` (new)
- **Notes:** Bootstrapped from a full structural sweep of `Bubo/` (~185 Swift files). Pages are facts-only: one page per top-level subdirectory under `modules/`, cross-cutting features under `concepts/`, composition root under `architecture/`. Detail level is intentionally shallow — expect organic growth via ingests. Source citations point to subdirectories where individual file/line refs would be brittle.

## [2026-05-11] ingest | Verify claims by reading source; add recurrence + undo pages

- **Trigger:** human request — "сделай все" (do all of the followups)
- **Touched:** `wiki/concepts/intents.md`, `wiki/concepts/genetic-algorithm.md`, `wiki/concepts/cloudkit-sync.md`, `wiki/concepts/fitness-objectives.md`, `wiki/modules/services.md`, `wiki/modules/views.md`, `wiki/concepts/cloudkit-sync.md` (`Sources:` fix), `wiki/concepts/recurrence.md` (new), `wiki/concepts/undo.md` (new), `wiki/index.md`
- **Notes:**
  - **`IntentCompiler`:** read top of `Bubo/Optimizer/Intents/IntentCompiler.swift`. It's not a constraint translator — it's an 8-stage graph executor that compiles intents and runs the GA itself. Rewrote the pipeline section of `intents.md`.
  - **`MutationBandit`:** read `Bubo/Optimizer/GACore/MutationBandit.swift`. It's a LinUCB contextual bandit over five named operators (`shift`, `moveDay`, `snap`, `guided`, `lnsDay`). Conditions on graph-derived [0,1] features. Rewrote the adaptive-elements section of `genetic-algorithm.md` with exact operator names and behaviour.
  - **`UpsertReconciler`:** read `Bubo/Services/Persistence/UpsertReconciler.swift` + call sites. It's an `enum` namespace with one static `reconcile(...)`, called from every store save path (not specifically on remote import). Fixed claim in `cloudkit-sync.md` and `services.md`.
  - **`DayPartitionedObjective`:** found protocol declared in `Bubo/Optimizer/Fitness/FitnessEvaluator.swift:143`. Added a section to `fitness-objectives.md` describing delta evaluation and the explicit classification table at `FitnessEvaluator.swift:324`.
  - **Hotspots:** measured top SwiftUI files. `MenuBarView.swift` 3521, `BacklogFullscreenView.swift` 2036, `BacklogTaskRow.swift` 1341, `CommandPalette.swift` 1275, `EventRowView.swift` 1095. Added a "Size hotspots" section to `views.md` flagging them for refactor candidacy (no bugs, but slow new contributors and inflate merge conflicts).
  - **`recurrence.md`** (new): two unrelated recurrence systems. `RecurrenceEngine` operates on free-form `BacklogTask.recurrenceTag` strings and returns the next deadline. `RecurrenceExpander` operates on `CalendarEvent.recurrenceRule` (RFC 5545) and expands to occurrences inside a window. Exclusion uses `ExcludedOccurrenceStore` (ids) + iCal EXDATE (dates via `ICalDateParser`). Hard limits per frequency documented.
  - **`undo.md`** (new): `UndoService` is `@MainActor @Observable`, single-slot stack (`lastAction`), `push(label, duration: 5, undo:)` API, 5s auto-dismiss via `dismissTask`. Renders through `ToastView`. Implements PRINCIPLES §5.
  - Added both new pages to `index.md`.
  - **Sources lint fix:** `cloudkit-sync.md` cited a non-existent path `Bubo/Services/Persistence/CloudKitSyncMonitor.swift`. The actual file is `Bubo/Services/CloudKitSyncMonitor.swift`. Corrected.
  - **What remains unverified:** detail descriptions in `modules/optimizer.md` table rows (`IslandModelGA`, `PathRelinking`, `TabuMemory`, `SymmetryBreaker`, etc.) were not read line-by-line. These will be verified opportunistically on future ingests of those files.

## [2026-05-11] lint | Post-bootstrap fact reconciliation

- **Trigger:** human request — "поправь" after self-audit of bootstrap accuracy
- **Touched:** `wiki/modules/services.md`, `wiki/modules/skins.md`, `wiki/modules/tests.md`, `wiki/modules/optimizer.md`, `wiki/concepts/notifications-bus.md`, `wiki/concepts/full-screen-alerts.md`, `wiki/concepts/fitness-objectives.md`, `wiki/concepts/intents.md`, `wiki/architecture/persistence.md`, `wiki/architecture/event-pipeline.md`, `wiki/architecture/overview.md`
- **Notes:** Grep-verified Notification.Name declarations across `Bubo/` — replaced hand-waved notification list in `notifications-bus.md` with a complete table of declarations + post sites + listeners (20 names found). Corrected directory facts: `NotificationScheduler` and `EventKitSyncCoordinator` live in `Services/Reminders/` (not `Services/Persistence/`); `CloudKitSyncMonitor` and `CloudServicesCoordinator` live flat in `Services/`. Counted fitness objectives — exactly 16, list now alphabetised and matches `Optimizer/Fitness/Objectives/` 1:1. `IntentLearner.swift` is only in `Optimizer/Learning/` — corrected the false "duplicated in both" claim. Added `InMemoryStores.swift`, `FakeCloudServices.swift`, `TEMPLATE.json`, `buboskin.schema.json` to module pages. Rewrote `tests.md` — the target is named `OptimizerTests` but covers cloud sync, app composition, backlog, EventKit (mocked), etc.
