# Wiki log

Append-only chronological record of wiki operations. Newest at the bottom. See `../AGENTS.md` §4.4 for entry format.

---

## [2026-05-11] bootstrap | Initial wiki from full Bubo/ sweep

- **Trigger:** human request — "create automatic LLM wiki per Karpathy gist"
- **Touched:** entire `wiki/` tree, `AGENTS.md` (new)
- **Notes:** Bootstrapped from a full structural sweep of `Bubo/` (~185 Swift files). Pages are facts-only: one page per top-level subdirectory under `modules/`, cross-cutting features under `concepts/`, composition root under `architecture/`. Detail level is intentionally shallow — expect organic growth via ingests. Source citations point to subdirectories where individual file/line refs would be brittle.
