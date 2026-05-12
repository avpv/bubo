# Module: proxy

> **Kind:** module
> **Sources:** proxy/
> **Last ingest:** 2026-05-12
> **Related:** [`../concepts/agent-service.md`](../concepts/agent-service.md), [`services.md`](services.md)

## What it is

A **Cloudflare Worker** written in **TypeScript** that proxies AI requests from the Bubo macOS app to the **DeepSeek API** with per-device rate limiting. It is not a Node server. The previous wiki claim ("small Node proxy" forwarding to Anthropic) was wrong on both counts — see [`../concepts/agent-service.md`](../concepts/agent-service.md) for the Anthropic→DeepSeek migration context.

## Layout

```
proxy/
├── README.md           # 82 lines — setup, config, request flow diagram
├── package.json        # name: "bubo-agent-proxy". Devdeps: wrangler, @cloudflare/workers-types, typescript
├── src/
│   └── index.ts        # 271 lines — the entire Worker
├── tsconfig.json       # TS config
└── wrangler.toml       # Cloudflare Worker config (KV namespace binding, secrets, route)
```

## What it does

1. Holds the API key server-side as a Wrangler secret (`DEEPSEEK_API_KEY` env binding) so it can't be extracted from the app binary.
2. Enforces a per-device daily quota via Cloudflare KV.
3. Forwards `POST /v1/agent/recipe` requests to `https://api.deepseek.com/chat/completions`.
4. Returns rate-limit headers so the app can show remaining quota.

## Constants (verified in `src/index.ts`)

| Constant | Value | Line | Notes |
|---|---|---|---|
| `DAILY_LIMIT` | `20` | `:17` | Requests per device per day |
| `DEEPSEEK_API` | `https://api.deepseek.com/chat/completions` | `:18` | The upstream target |

## Per-device rate limiting

Requests must include `X-Device-Id: <uuid>` (anonymous, generated once by the Mac app and persisted in `UserDefaults`). The Worker hashes the device id with a cheap non-cryptographic hash for log correlation without leaking the raw UUID.

State lives in the Cloudflare KV namespace `RATE_LIMITS`. Setup requires creating the namespace (`npx wrangler kv namespace create RATE_LIMITS`) and pasting its id into `wrangler.toml`.

## Logging

Structured JSON-per-line written to stdout, ingestible by Cloudflare Logpush or `wrangler tail --format=json` (`src/index.ts:25–48`). Field shape is intentionally stable so downstream consumers can key off `event` and `device_id_hash`.

## Deploy

`npm run deploy` → `wrangler deploy`. Local dev: `npm run dev`. README has the full bootstrap sequence (KV namespace creation, secret setup, first deploy).

## Maintenance

Out of scope of the Swift wiki — when ingesting changes that only touch `proxy/`, update this page's `Last ingest` and add an entry in `log.md` but do not propagate to other module pages.
