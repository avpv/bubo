# Post-join ribbon (J1)

> **Kind:** concept
> **Sources:** Bubo/AppDelegate.swift, Bubo/Views/JoinRibbonView.swift
> **Last ingest:** 2026-05-11
> **Related:** [`full-screen-alerts.md`](full-screen-alerts.md), [`../modules/app.md`](../modules/app.md)

## What

After the user opens a meeting URL (Zoom/Meet/Teams/etc.) from a full-screen alert, a slim ribbon appears at the top of the screen with:

- the current meeting title and remaining time,
- a "join next" prompt if another meeting is within a tight window,
- a quick dismiss / "stop tracking" affordance.

## How it fires

`AppDelegate` listens for join actions emitted by `FullScreenAlertView` and instantiates a single `NSPanel` (`AppDelegate.swift:44`, `joinRibbonWindow: NSPanel?`) hosting `JoinRibbonView` (`:503`) at the top of the active screen. The panel is borderless, click-through outside the ribbon hit area, and dismisses when the meeting ends or the user explicitly closes it. Auto-dismiss is driven by `joinRibbonAutoDismissTask: Task<Void, Never>?` (`:45`).

## Why a separate component

The full-screen alert occupies the user's attention briefly; the ribbon is the persistent low-key follow-up. Keeping them as two windows allows independent dismissal and avoids re-presenting the dark takeover after the user has already engaged.
