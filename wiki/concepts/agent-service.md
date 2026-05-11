# Agent service (DeepSeek integration)

> **Kind:** concept
> **Sources:** Bubo/Application/AgentService.swift, Bubo/Infrastructure/Keychain.swift, Bubo/Optimizer/Intents/LLMIntentBridge.swift, Bubo/Presentation/Views/Settings/AITabView.swift, proxy/
> **Last ingest:** 2026-05-11
> **Related:** [`intents.md`](intents.md), [`../modules/proxy.md`](../modules/proxy.md)

## Provider: DeepSeek (mid-migration)

The codebase is in the middle of an **Anthropic → DeepSeek** migration. The actual runtime calls DeepSeek's OpenAI-compatible endpoint, but several doc comments and identifiers still reference Anthropic/Claude. Source of truth is the code, not the comments.

| Surface | Truth | Stale comment |
|---|---|---|
| Direct endpoint | `https://api.deepseek.com/chat/completions` (`AgentService.swift:94`) | Header at `:9` still says "Uses Claude tool_use" and `:15–16` says "user provides their own Anthropic API key" |
| Request model | `model: "deepseek-chat"` (`AgentService.swift:126`) | — |
| Request body | OpenAI-compatible (comment at `:124` explicitly notes "OpenAI-Compatible API Types (DeepSeek)" at `:407`) | — |
| Keychain key | `"anthropic-api-key"` (`AgentService.swift:61`) | Historical name — the value is a DeepSeek key. Migration risk if changed (existing installs would lose stored keys) |
| User-facing error | "Add your DeepSeek API key in Settings → AI Assistant" (`:396`) | — |
| Proxy backend | `DEEPSEEK_API_KEY` env var, `https://api.deepseek.com/chat/completions` (`proxy/src/index.ts`) | `proxy/src/index.ts:6` still says "Sits between the Bubo macOS app and the Anthropic API" |

When ingesting future changes in this area, do not "fix" the wiki to say Anthropic again on the basis of comments — verify against the endpoint constants.

## What

`AgentService` (`@MainActor @Observable final class AgentService` at `AgentService.swift:19`) is the in-app client for the LLM. It turns natural-language requests (from the command palette) into structured `ScheduleIntent`s. Tool-use semantics are preserved via the OpenAI-compatible function-calling schema, not Anthropic's `tool_use`.

## Modes

| Mode | Endpoint | API key | Rate limits |
|---|---|---|---|
| **Built-in** (default) | `proxy/` Cloudflare Worker | App-managed (server-side) | Per-device, enforced by the Worker via Cloudflare KV |
| **Own key** | `api.deepseek.com` direct | User's DeepSeek key (via `Keychain` at key `"anthropic-api-key"`) | DeepSeek account limits |

Mode is chosen in `AITabView` (`Presentation/Views/Settings/AITabView.swift`). Stored in `UserDefaults["BuboAgentMode"]`. Switching is hot — no restart.

## Tool-use flow

1. User types in `CommandPalette`.
2. `AgentService` sends the prompt with an OpenAI-compatible tool definition matching `ScheduleIntent`.
3. The model responds with a tool call whose arguments are decodable as one or more `ScheduleIntent`s.
4. `LLMIntentBridge` (`Bubo/Optimizer/Intents/LLMIntentBridge.swift:15`) decodes and hands them to `IntentCompiler`.

## Rate limit display

`AgentService` exposes `remainingRequests`, `requestLimit`, and `limitResetsAt` as observable properties. `AITabView` shows remaining requests / reset time so the user knows when built-in mode will throttle.

## Failure modes

- Network down → `NetworkMonitor` reflects it; the command palette degrades to local intent presets (`IntentPresets.swift`).
- Tool-call parse error → service sets `lastError`; palette surfaces a "couldn't understand" toast and offers the user to refine.
- Proxy 429 → "rate limited" toast with reset hint.

## Keychain

User-provided API keys are stored in the macOS Keychain via `Infrastructure/Keychain.swift`. The key name is the legacy string `"anthropic-api-key"` (`AgentService.swift:61`) — do not rename without a migration step or existing installs lose stored keys.

## Device ID

A stable anonymous device identifier (`AgentService.swift:81`, key `"bubo-device-id"` at `:98`) is generated once and persisted in `UserDefaults`. Sent as the HTTP header `x-device-id` (`:212`). Used by the proxy for per-device rate limiting; not sensitive data.
