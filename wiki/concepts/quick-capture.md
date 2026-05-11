# Quick capture (⌃⇧⌘Space)

> **Kind:** concept
> **Sources:** Bubo/AppDelegate.swift, Bubo/Views/QuickCaptureView.swift, Bubo/Views/NewTaskView.swift, Bubo/Services/QuickCaptureBridge.swift
> **Last ingest:** 2026-05-11
> **Related:** [`../modules/app.md`](../modules/app.md), [`../modules/services.md`](../modules/services.md)

## What

A global hotkey (default ⌃⇧⌘Space) opens a small overlay anywhere in macOS to capture a new backlog task without switching focus.

## Flow

1. `AppDelegate` registers the global shortcut via Carbon / `RegisterEventHotKey`.
2. On press, it presents a borderless floating window hosting `QuickCaptureView` centred on the focused screen.
3. The user types a task. `QuickCaptureView` writes the buffer into `QuickCaptureBridge` (`Services/QuickCaptureBridge.swift`).
4. `⇧↩` opens the full `NewTaskView` pre-filled from the bridge buffer for detailed editing (deadline, recurrence, project, subtasks).
5. Plain `↩` commits directly via `BacklogService.add(...)` which persists to `BacklogTaskStore` and posts `.taskAdded`.

## Why a bridge

`QuickCaptureBridge` exists so the lightweight overlay (which should dismiss instantly on `↩`) and the full editor (which lives inside `MenuBarView`'s navigation stack) share state without coupling.
