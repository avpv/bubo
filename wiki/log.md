# Wiki log

Append-only chronological record of wiki operations. Newest at the bottom. See `../AGENTS.md` §4.4 for entry format.

---

## [2026-05-11] bootstrap | Initial wiki from full Bubo/ sweep

- **Trigger:** human request — "create automatic LLM wiki per Karpathy gist"
- **Touched:** entire `wiki/` tree, `AGENTS.md` (new)
- **Notes:** Bootstrapped from a full structural sweep of `Bubo/` (~185 Swift files). Pages are facts-only: one page per top-level subdirectory under `modules/`, cross-cutting features under `concepts/`, composition root under `architecture/`. Detail level is intentionally shallow — expect organic growth via ingests. Source citations point to subdirectories where individual file/line refs would be brittle.

## [2026-05-11] lint | Post-bootstrap fact reconciliation

- **Trigger:** human request — "поправь" after self-audit of bootstrap accuracy
- **Touched:** `wiki/modules/services.md`, `wiki/modules/skins.md`, `wiki/modules/tests.md`, `wiki/modules/optimizer.md`, `wiki/concepts/notifications-bus.md`, `wiki/concepts/full-screen-alerts.md`, `wiki/concepts/fitness-objectives.md`, `wiki/concepts/intents.md`, `wiki/architecture/persistence.md`, `wiki/architecture/event-pipeline.md`, `wiki/architecture/overview.md`
- **Notes:** Grep-verified Notification.Name declarations across `Bubo/` — replaced hand-waved notification list in `notifications-bus.md` with a complete table of declarations + post sites + listeners (20 names found). Corrected directory facts: `NotificationScheduler` and `EventKitSyncCoordinator` live in `Services/Reminders/` (not `Services/Persistence/`); `CloudKitSyncMonitor` and `CloudServicesCoordinator` live flat in `Services/`. Counted fitness objectives — exactly 16, list now alphabetised and matches `Optimizer/Fitness/Objectives/` 1:1. `IntentLearner.swift` is only in `Optimizer/Learning/` — corrected the false "duplicated in both" claim. Added `InMemoryStores.swift`, `FakeCloudServices.swift`, `TEMPLATE.json`, `buboskin.schema.json` to module pages. Rewrote `tests.md` — the target is named `OptimizerTests` but covers cloud sync, app composition, backlog, EventKit (mocked), etc.
