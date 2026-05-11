# Module: proxy

> **Kind:** module
> **Sources:** proxy/
> **Last ingest:** 2026-05-11
> **Related:** [`../concepts/agent-service.md`](../concepts/agent-service.md), [`services.md`](services.md)

## What it is

A small reverse-proxy server that sits between the Bubo app and the Anthropic API for users on the **built-in** AI mode (no API key required from them). It:

- holds a service-wide Anthropic API key,
- enforces per-user rate limits,
- forwards requests to `api.anthropic.com` and streams responses back.

Users in **own-key** mode bypass the proxy and call Anthropic directly with their own API key stored via `Keychain` in `Services/Keychain.swift`.

## Where it runs

Deployed independently of the Mac app. The Mac app's `AgentService` (`Services/AgentService.swift`) is configured to talk to the proxy URL when in built-in mode. See [`../concepts/agent-service.md`](../concepts/agent-service.md) for the client side.

## Maintenance

Out of scope of the Swift wiki — when ingesting changes that only touch `proxy/`, update this page's `Last ingest` and add an entry in `log.md` but do not propagate to other module pages.
