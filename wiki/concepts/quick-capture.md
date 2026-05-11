# Quick capture (⌃⇧⌘Space)

> **Kind:** concept
> **Sources:** Bubo/Composition/AppDelegate.swift, Bubo/Presentation/Views/QuickCaptureView.swift, Bubo/Presentation/Views/NewTaskView.swift, Bubo/Presentation/QuickCaptureBridge.swift
> **Last ingest:** 2026-05-11
> **Related:** [`../modules/app.md`](../modules/app.md), [`../modules/services.md`](../modules/services.md)

## What

A global hotkey (default ⌃⇧⌘Space) opens a small overlay anywhere in macOS to capture a new backlog task without switching focus.

## Flow

1. `AppDelegate` installs a pair of `NSEvent` monitors in `installQuickCaptureHotkey()` (`AppDelegate.swift:297`): one **local** (`addLocalMonitorForEvents`, fires when Bubo has focus, swallows the chord on match) and one **global** (`addGlobalMonitorForEvents`, fires when another app is foreground; cannot consume the event so the chord must be unique). Key code `49` (Space) + `.control + .shift + .command` (`:291`, `:295`). Global monitor needs Accessibility permission to function. Carbon `RegisterEventHotKey` is **not** used — comment at `:286–288` notes it as an upgrade path if the chord becomes user-customisable.
2. On press, `toggleQuickCapture()` presents a borderless floating window hosting `QuickCaptureView` centred on the focused screen.
3. The user types a task. `QuickCaptureView` writes the buffer into `QuickCaptureBridge` (`Presentation/QuickCaptureBridge.swift`).
4. `⇧↩` opens the full `NewTaskView` pre-filled from the bridge buffer for detailed editing (deadline, recurrence, project, subtasks).
5. Plain `↩` commits directly via `BacklogService.add(...)` which persists to `BacklogTaskStore` and posts `.taskAdded`.

## Why a bridge

`QuickCaptureBridge` exists so the lightweight overlay (which should dismiss instantly on `↩`) and the full editor (which lives inside `MenuBarView`'s navigation stack) share state without coupling.
