# AGENTS.md — Instructions for LLM agents working on Bubo

This file is the **schema layer** for the LLM-maintained wiki at [`wiki/`](wiki/). It tells any agent (Claude Code, Codex, etc.) how to read, update, and lint the wiki when working on this repo. The pattern follows Andrej Karpathy's [LLM wiki gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f).

If you only read one section, read [Workflows](#workflows).

---

## 1. What this repo is

Bubo is a native macOS menu-bar calendar with full-screen meeting alerts and a Pomodoro-aware scheduling optimizer. The product overview lives in [`README.md`](README.md). Design rules live in [`docs/design/PRINCIPLES.md`](docs/design/PRINCIPLES.md).

The Swift code is split into three SwiftPM targets:

- **`BuboDomain`** (`Sources/BuboDomain/`) — pure value types: `CalendarEvent`, `BacklogTask`, `RecurrenceRule`, `Period`, `PomodoroConfig`, `OptimizableEvent`, `ReminderSettings`. No deps on other targets.
- **`BuboOptimizer`** (`Sources/BuboOptimizer/`) — the multi-objective GA. Depends on `BuboDomain` for value types; no service or UI deps.
- **`Bubo`** (`Bubo/`) — the macOS executable: `Application/`, `Presentation/`, `Composition/`, `Infrastructure/`. Depends on both `BuboDomain` and `BuboOptimizer`.

Tests are under `Tests/BuboTests/` and `@testable import` all three targets. There is also a small Node proxy under `proxy/`.

## 2. Three layers

| Layer | What | Who edits |
|---|---|---|
| **Sources** | `Bubo/**/*.swift`, `Sources/**/*.swift`, `docs/**`, `proxy/**`, `Tests/**`, `README.md` | Humans (and agents during code work) |
| **Wiki** | `wiki/**/*.md` — synthesized knowledge: module maps, concept pages, decisions | Agents (this is yours) |
| **Schema** | This file (`AGENTS.md`) | Humans propose, agents follow |

The wiki is **derivative**. If wiki and source disagree, source wins — fix the wiki.

## 3. Wiki layout

```
wiki/
├── README.md           # Reader-facing: what this is, how to navigate
├── index.md            # Catalog of every page with one-line summaries
├── log.md              # Append-only chronological log of ingests/queries/lints
├── architecture/       # Cross-cutting architecture pages
├── modules/            # One page per top-level Bubo/ or Sources/Bubo* subdirectory
└── concepts/           # Cross-cutting features and patterns
```

Every wiki page MUST start with this frontmatter-ish header:

```markdown
# <Page title>

> **Kind:** module | concept | architecture
> **Sources:** Bubo/Application/ReminderService.swift, Sources/BuboDomain/CalendarEvent.swift
> **Last ingest:** 2026-05-11
> **Related:** [concepts/full-screen-alerts](../concepts/full-screen-alerts.md), [modules/optimizer](../modules/optimizer.md)
```

- **Sources** lists the canonical paths the page is derived from. Use repo-relative paths.
- **Last ingest** is the ISO date the page was last re-synced against sources.
- **Related** is at least one inbound or sibling page. No orphans.

Internal links use repo-relative markdown paths. Code references use the `path/to/file.swift:line` convention so editors can jump.

## 4. Workflows

### 4.1 Ingest (after code change)

Trigger: a PR or commit touches `Bubo/`, `proxy/`, `docs/`, `Tests/`, or `README.md`.

Procedure:

1. Diff the change. Note added/removed/renamed Swift types, files, frameworks.
2. For each affected source file, find the wiki pages that list it under `Sources:`. Use `grep -rln "Bubo/Services/Foo.swift" wiki/`.
3. Update those pages:
   - Rewrite the section that describes the changed type.
   - Update `Last ingest` to today's date.
   - If a new public type appeared, add it to the relevant module page and to `index.md`.
   - If a file was deleted, remove references and consider deleting orphaned pages.
4. Append a log entry to `wiki/log.md` (see [§4.4](#44-log-entries)).
5. Re-check cross-references: every page named in the change should still link back to at least one sibling or parent.

**Budget per ingest:** keep edits proportional to the diff. A one-line code change should not rewrite a 200-line wiki page. If you find yourself rewriting a whole page from a small change, stop and ask the human.

### 4.2 Query

Trigger: a human asks a question about the codebase.

Procedure:

1. Read `wiki/index.md` first. Pick the 1–3 most relevant pages.
2. Read those pages. If they cover the question, answer with citations to wiki pages **and** the source files they reference.
3. If the wiki is missing something useful, propose a new page or a section addition — don't write it unprompted unless the question itself is "document X".
4. Optionally: log the query as a `query` entry if the answer surfaced a gap.

### 4.3 Lint (on demand or weekly)

Health checks to run when the human says "lint the wiki":

- **Stale ingest:** any page whose `Last ingest` is older than its newest cited source file's git mtime. Flag it.
- **Missing sources:** any path under `Sources:` that no longer exists in the repo.
- **Orphans:** any page not linked from `index.md` or any sibling.
- **Dangling links:** broken relative links.
- **Contradictions:** pages making opposite claims about the same type. Flag, don't silently resolve — ask the human.
- **Index drift:** files in `wiki/{modules,concepts,architecture}/` not listed in `index.md`, or listed entries that no longer exist.

Report findings as a checklist. Do not auto-fix beyond trivial dead-link repairs without confirmation.

### 4.4 Log entries

Append to the bottom of `wiki/log.md`. One entry per operation. Format:

```markdown
## [YYYY-MM-DD] <kind> | <short subject>

- **Trigger:** <commit sha / PR / human request>
- **Touched:** wiki/modules/foo.md, wiki/concepts/bar.md
- **Notes:** <one sentence — what changed, what didn't>
```

`<kind>` is one of: `ingest`, `query`, `lint`, `bootstrap`, `refactor`.

## 5. Conventions for writing pages

- **Facts over prose.** Bullets, tables, file/line citations. The wiki is a reference, not a tutorial.
- **No marketing copy.** Describe what the code does, not why it's great.
- **Cite source.** Every non-trivial claim points to a file path. When the page makes a claim that isn't obvious from a file, link the file.
- **Don't paste large code blocks.** Quote the smallest excerpt that makes the point, with a `path:line` citation above it.
- **Don't duplicate.** If two pages describe the same thing, one of them should be a stub linking to the canonical page.
- **Keep pages short.** Soft cap: 200 lines. If a page grows past that, split it.
- **No emojis.** No decorative ASCII. Tables and headings only.
- **English.** Code identifiers and the codebase are English; keep the wiki English even when the human conversation is not.

## 6. When NOT to update the wiki

- Whitespace-only or comment-only diffs.
- Test changes that don't alter behavior under test (rename, refactor of a single test).
- WIP commits on feature branches before review — wait for merge to main.
- Private/`fileprivate` implementation details that no other page references.

## 7. Bootstrap

The wiki was bootstrapped on 2026-05-11 from a full sweep of `Bubo/`. See `wiki/log.md` for the bootstrap entry. Initial pages are facts-only and may be thinner than they should be — fill in detail organically as ingests happen.
