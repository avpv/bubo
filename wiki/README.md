# Bubo LLM Wiki

This directory is an **LLM-maintained knowledge base** about the Bubo codebase. It is generated and kept current by AI agents working on the repo (Claude Code primarily). It is not a user manual — for a product overview see [`../README.md`](../README.md).

The pattern follows Andrej Karpathy's [LLM wiki gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f): a persistent, compounding artifact synthesized from sources, with cross-references pre-resolved.

## Where to start

- [`index.md`](index.md) — catalog of every page
- [`architecture/overview.md`](architecture/overview.md) — how the app is composed
- [`modules/`](modules/) — one page per top-level `Bubo/` subdirectory
- [`concepts/`](concepts/) — cross-cutting features (full-screen alerts, Pomodoro, GA optimizer, intents, skins)
- [`log.md`](log.md) — chronological record of ingests, queries, and lints

## Who edits this

LLM agents — see [`../AGENTS.md`](../AGENTS.md) for the schema and workflows (ingest, query, lint).

Humans can edit too: fix mistakes, add a stub, leave a note. Agents will re-ingest on the next code change.

## Conventions in one paragraph

Every page starts with a `Sources:` header listing the source files it derives from. Code references use the `path/to/file.swift:line` convention. Pages cap at ~200 lines. Facts only — no marketing copy. See [`../AGENTS.md`](../AGENTS.md) §5.
