# Agent service (Claude integration)

> **Kind:** concept
> **Sources:** Bubo/Services/AgentService.swift, Bubo/Services/Keychain.swift, Bubo/Optimizer/Intents/LLMIntentBridge.swift, Bubo/Views/Settings/AITabView.swift, proxy/
> **Last ingest:** 2026-05-11
> **Related:** [`intents.md`](intents.md), [`../modules/proxy.md`](../modules/proxy.md)

## What

`AgentService` is the in-app client for Anthropic's Claude. It turns natural-language requests (from the command palette) into structured `ScheduleIntent`s using Claude's tool_use schema.

## Modes

| Mode | Endpoint | API key | Rate limits |
|---|---|---|---|
| Built-in | `proxy/` server | App-managed | Per-user, enforced server-side |
| Own key | `api.anthropic.com` direct | User's key (via `Keychain`) | Anthropic account limits |

Mode is chosen in `AITabView` (`Views/Settings/AITabView.swift`). Switching is hot — no restart.

## Tool-use flow

1. User types in `CommandPalette`.
2. `AgentService` sends the prompt with a tool definition matching `ScheduleIntent`.
3. Claude responds with a tool_use call whose input is parseable as one or more `ScheduleIntent`s.
4. `LLMIntentBridge` decodes and hands them to `IntentCompiler`.

## Rate limit display

`AgentService` exposes the current rate-limit window state as observable properties; `AITabView` shows remaining requests / reset time so the user knows when built-in mode will throttle.

## Failure modes

- Network down → `NetworkMonitor` reflects it; the command palette degrades to local intent presets (`IntentPresets.swift`).
- Tool_use parse error → service returns a structured error, palette surfaces a "couldn't understand" toast and offers the user to refine.
- Proxy 429 → "rate limited" toast with reset hint.

## Keychain

User-provided API keys are stored in the macOS Keychain via `Services/Keychain.swift`. Never read into `ReminderSettings` or written to disk.
