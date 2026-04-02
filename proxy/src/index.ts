/**
 * Bubo Agent Proxy — Cloudflare Worker
 *
 * Sits between the Bubo macOS app and the Anthropic API.
 * - Holds the API key server-side (never sent to clients)
 * - Enforces per-device rate limits via KV storage
 * - Returns rate-limit headers so the app can show remaining quota
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  RATE_LIMITS: KVNamespace;
}

// ── Config ──────────────────────────────────────────────

const DAILY_LIMIT = 20; // requests per device per day
const ANTHROPIC_API = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";

// ── Entry Point ─────────────────────────────────────────

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // CORS preflight
    if (request.method === "OPTIONS") {
      return corsResponse(new Response(null, { status: 204 }));
    }

    // Only POST to the recipe endpoint
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/v1/agent/recipe") {
      return corsResponse(
        new Response(JSON.stringify({ error: "Not found" }), {
          status: 404,
          headers: { "content-type": "application/json" },
        })
      );
    }

    // Require device ID
    const deviceId = request.headers.get("x-device-id");
    if (!deviceId || deviceId.length < 10) {
      return corsResponse(
        new Response(JSON.stringify({ error: "Missing x-device-id header" }), {
          status: 400,
          headers: { "content-type": "application/json" },
        })
      );
    }

    // ── Rate Limiting ─────────────────────────────────

    const today = new Date().toISOString().slice(0, 10); // "2026-04-02"
    const kvKey = `rl:${deviceId}:${today}`;

    const stored = await env.RATE_LIMITS.get(kvKey);
    const used = stored ? parseInt(stored, 10) : 0;

    if (used >= DAILY_LIMIT) {
      const resetAt = getEndOfDayUTC();
      return corsResponse(
        new Response(JSON.stringify({ error: "Daily limit exceeded" }), {
          status: 429,
          headers: {
            "content-type": "application/json",
            "Retry-After": String(Math.ceil((resetAt - Date.now()) / 1000)),
            "X-RateLimit-Limit": String(DAILY_LIMIT),
            "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset": String(Math.floor(resetAt / 1000)),
          },
        })
      );
    }

    // ── Forward to Anthropic ──────────────────────────

    const body = await request.text();

    // Basic validation: must be JSON with messages array
    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(body);
    } catch {
      return corsResponse(
        new Response(JSON.stringify({ error: "Invalid JSON body" }), {
          status: 400,
          headers: { "content-type": "application/json" },
        })
      );
    }

    if (!Array.isArray(parsed.messages) || parsed.messages.length === 0) {
      return corsResponse(
        new Response(
          JSON.stringify({ error: "Request must contain messages array" }),
          {
            status: 400,
            headers: { "content-type": "application/json" },
          }
        )
      );
    }

    // Forward with the server-side API key
    const anthropicResponse = await fetch(ANTHROPIC_API, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "anthropic-version": ANTHROPIC_VERSION,
        "x-api-key": env.ANTHROPIC_API_KEY,
      },
      body,
    });

    // Increment counter only on successful API call
    const newUsed = used + 1;
    // KV TTL: expire at end of day + 1 hour buffer
    const ttlSeconds = Math.ceil((getEndOfDayUTC() - Date.now()) / 1000) + 3600;
    await env.RATE_LIMITS.put(kvKey, String(newUsed), {
      expirationTtl: Math.max(ttlSeconds, 60),
    });

    const remaining = DAILY_LIMIT - newUsed;
    const resetAt = getEndOfDayUTC();

    // Stream the Anthropic response back with rate-limit headers
    const responseHeaders = new Headers(anthropicResponse.headers);
    responseHeaders.set("X-RateLimit-Limit", String(DAILY_LIMIT));
    responseHeaders.set("X-RateLimit-Remaining", String(Math.max(0, remaining)));
    responseHeaders.set("X-RateLimit-Reset", String(Math.floor(resetAt / 1000)));

    return corsResponse(
      new Response(anthropicResponse.body, {
        status: anthropicResponse.status,
        headers: responseHeaders,
      })
    );
  },
};

// ── Helpers ──────────────────────────────────────────────

/** Returns Unix timestamp (ms) for midnight UTC of the next day. */
function getEndOfDayUTC(): number {
  const now = new Date();
  const tomorrow = new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1)
  );
  return tomorrow.getTime();
}

/** Wrap a Response with CORS headers for the Bubo app. */
function corsResponse(response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set("Access-Control-Allow-Origin", "*");
  headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
  headers.set(
    "Access-Control-Allow-Headers",
    "content-type, x-device-id"
  );
  headers.set(
    "Access-Control-Expose-Headers",
    "X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset"
  );
  return new Response(response.body, {
    status: response.status,
    headers,
  });
}
