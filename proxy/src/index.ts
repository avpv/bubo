/**
 * Bubo Agent Proxy — Cloudflare Worker
 *
 * Sits between the Bubo macOS app and the DeepSeek API.
 * - Holds the API key server-side (never sent to clients)
 * - Enforces per-device rate limits via KV storage
 * - Returns rate-limit headers so the app can show remaining quota
 */

interface Env {
  DEEPSEEK_API_KEY: string;
  RATE_LIMITS: KVNamespace;
}

// ── Config ──────────────────────────────────────────────

const DAILY_LIMIT = 20; // requests per device per day
const DEEPSEEK_API = "https://api.deepseek.com/chat/completions";

// ── Structured Logging ──────────────────────────────────

// Every log line is a single JSON object on stdout so Cloudflare Logpush /
// `wrangler tail --format=json` can ingest it without extra parsing. The
// field shape is intentionally stable — downstream consumers (dashboards,
// support tooling) key off `event` and `device_id_hash`.
type LogFields = Record<string, string | number | boolean | undefined>;

function log(
  level: "info" | "warn" | "error",
  event: string,
  fields: LogFields = {}
): void {
  const payload = {
    ts: new Date().toISOString(),
    level,
    event,
    ...fields,
  };
  const line = JSON.stringify(payload);
  if (level === "error") {
    console.error(line);
  } else if (level === "warn") {
    console.warn(line);
  } else {
    console.log(line);
  }
}

// Cheap, non-cryptographic hash so device IDs in logs correlate across
// lines without leaking the raw UUID. Good enough for aggregation; not a
// security boundary.
function hashDeviceId(id: string): string {
  let h = 2166136261;
  for (let i = 0; i < id.length; i++) {
    h ^= id.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0).toString(16).padStart(8, "0");
}

// ── Entry Point ─────────────────────────────────────────

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const startedAt = Date.now();
    const url = new URL(request.url);

    // CORS preflight
    if (request.method === "OPTIONS") {
      return corsResponse(new Response(null, { status: 204 }));
    }

    // Only POST to the recipe endpoint
    if (request.method !== "POST" || url.pathname !== "/v1/agent/recipe") {
      log("warn", "route_not_found", {
        method: request.method,
        path: url.pathname,
      });
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
      log("warn", "missing_device_id");
      return corsResponse(
        new Response(JSON.stringify({ error: "Missing x-device-id header" }), {
          status: 400,
          headers: { "content-type": "application/json" },
        })
      );
    }

    const deviceHash = hashDeviceId(deviceId);

    // ── Rate Limiting ─────────────────────────────────

    const today = new Date().toISOString().slice(0, 10); // "2026-04-02"
    const kvKey = `rl:${deviceId}:${today}`;

    const stored = await env.RATE_LIMITS.get(kvKey);
    const used = stored ? parseInt(stored, 10) : 0;

    if (used >= DAILY_LIMIT) {
      const resetAt = getEndOfDayUTC();
      log("warn", "rate_limited", {
        device_id_hash: deviceHash,
        used,
        limit: DAILY_LIMIT,
        reset_at: Math.floor(resetAt / 1000),
      });
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

    // ── Forward to DeepSeek ──────────────────────────

    const body = await request.text();

    // Basic validation: must be JSON with messages array
    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(body);
    } catch (err) {
      log("warn", "invalid_json", {
        device_id_hash: deviceHash,
        body_size: body.length,
        error: err instanceof Error ? err.message : String(err),
      });
      return corsResponse(
        new Response(JSON.stringify({ error: "Invalid JSON body" }), {
          status: 400,
          headers: { "content-type": "application/json" },
        })
      );
    }

    if (!Array.isArray(parsed.messages) || parsed.messages.length === 0) {
      log("warn", "invalid_body", {
        device_id_hash: deviceHash,
        reason: "messages_missing_or_empty",
      });
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

    log("info", "request_forwarding", {
      device_id_hash: deviceHash,
      used,
      limit: DAILY_LIMIT,
      body_size: body.length,
    });

    // Forward with the server-side API key
    let upstreamResponse: Response;
    try {
      upstreamResponse = await fetch(DEEPSEEK_API, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "authorization": `Bearer ${env.DEEPSEEK_API_KEY}`,
        },
        body,
      });
    } catch (err) {
      log("error", "upstream_fetch_failed", {
        device_id_hash: deviceHash,
        duration_ms: Date.now() - startedAt,
        error: err instanceof Error ? err.message : String(err),
      });
      return corsResponse(
        new Response(JSON.stringify({ error: "Upstream unavailable" }), {
          status: 502,
          headers: { "content-type": "application/json" },
        })
      );
    }

    // Increment counter only on successful API call
    const newUsed = used + 1;
    // KV TTL: expire at end of day + 1 hour buffer
    const ttlSeconds = Math.ceil((getEndOfDayUTC() - Date.now()) / 1000) + 3600;
    await env.RATE_LIMITS.put(kvKey, String(newUsed), {
      expirationTtl: Math.max(ttlSeconds, 60),
    });

    const remaining = DAILY_LIMIT - newUsed;
    const resetAt = getEndOfDayUTC();

    log(
      upstreamResponse.status >= 500
        ? "error"
        : upstreamResponse.status >= 400
          ? "warn"
          : "info",
      "request_forwarded",
      {
        device_id_hash: deviceHash,
        status: upstreamResponse.status,
        duration_ms: Date.now() - startedAt,
        remaining,
        used: newUsed,
      }
    );

    // Stream the upstream response back with rate-limit headers
    const responseHeaders = new Headers(upstreamResponse.headers);
    responseHeaders.set("X-RateLimit-Limit", String(DAILY_LIMIT));
    responseHeaders.set("X-RateLimit-Remaining", String(Math.max(0, remaining)));
    responseHeaders.set("X-RateLimit-Reset", String(Math.floor(resetAt / 1000)));

    return corsResponse(
      new Response(upstreamResponse.body, {
        status: upstreamResponse.status,
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
