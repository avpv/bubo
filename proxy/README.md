# Bubo Agent Proxy

Cloudflare Worker that proxies AI requests from the Bubo app to the DeepSeek API with per-device rate limiting.

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

# Set your DeepSeek API key as a secret (never committed to git)
npx wrangler secret put DEEPSEEK_API_KEY

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
Bubo app                          Proxy (Cloudflare Worker)              DeepSeek API
   │                                     │                                    │
   │── POST /v1/agent/recipe ──────────>│                                    │
   │   X-Device-Id: <uuid>              │                                    │
   │   Body: chat completion request     │                                    │
   │                                     │── Check rate limit (KV) ──>       │
   │                                     │<─ 17/20 used today                │
   │                                     │                                    │
   │                                     │── POST /chat/completions ───────>│
   │                                     │   Authorization: Bearer sk-...     │
   │                                     │   Body: (forwarded)               │
   │                                     │                                    │
   │                                     │<─ 200 + response ────────────────│
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

DeepSeek Chat is significantly cheaper than other LLM APIs (~$0.0003/req for ~1K output tokens):
- 100 daily users × 20 req × $0.0003/req ≈ **$0.60/day**
- 1000 daily users × 20 req × $0.0003/req ≈ **$6/day**

Cloudflare Worker free tier: 100K requests/day.
