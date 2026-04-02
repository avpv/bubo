# Bubo Agent Proxy

Cloudflare Worker that proxies AI requests from the Bubo app to the Anthropic API with per-device rate limiting.

## Why a proxy?

The API key cannot be shipped inside the app binary — it would be extractable. The proxy holds the key server-side and enforces usage limits.

## Setup

```bash
cd proxy

# Install dependencies
npm install

# Create KV namespace for rate limiting
npx wrangler kv namespace create RATE_LIMITS

# Copy the namespace ID into wrangler.toml (replace REPLACE_WITH_KV_NAMESPACE_ID)

# Set your Anthropic API key as a secret (never committed to git)
npx wrangler secret put ANTHROPIC_API_KEY

# Deploy
npm run deploy
```

## Configuration

Edit `src/index.ts` to change:

| Constant | Default | Description |
|----------|---------|-------------|
| `DAILY_LIMIT` | `20` | Requests per device per day |

## How it works

```
Bubo app                          Proxy (Cloudflare Worker)              Anthropic API
   │                                     │                                    │
   │── POST /v1/agent/recipe ──────────>│                                    │
   │   X-Device-Id: <uuid>              │                                    │
   │   Body: Claude API request          │                                    │
   │                                     │── Check rate limit (KV) ──>       │
   │                                     │<─ 17/20 used today                │
   │                                     │                                    │
   │                                     │── POST /v1/messages ────────────>│
   │                                     │   x-api-key: sk-ant-...           │
   │                                     │   Body: (forwarded)               │
   │                                     │                                    │
   │                                     │<─ 200 + Claude response ─────────│
   │                                     │── Increment counter (KV) ──>      │
   │                                     │                                    │
   │<── 200 + Claude response ──────────│                                    │
   │    X-RateLimit-Limit: 20            │                                    │
   │    X-RateLimit-Remaining: 2         │                                    │
   │    X-RateLimit-Reset: 1714608000    │                                    │
```

## Rate limit headers

| Header | Description |
|--------|-------------|
| `X-RateLimit-Limit` | Total requests allowed per day |
| `X-RateLimit-Remaining` | Requests left in current window |
| `X-RateLimit-Reset` | Unix timestamp when the window resets |

## Local development

```bash
npm run dev
# Worker runs at http://localhost:8787
```

## Cost estimate

At ~20 requests/device/day with Claude Sonnet (~1K output tokens per recipe):
- 100 daily users × 20 req × $0.003/req ≈ **$6/day**
- 1000 daily users × 20 req × $0.003/req ≈ **$60/day**

Cloudflare Worker free tier: 100K requests/day.
