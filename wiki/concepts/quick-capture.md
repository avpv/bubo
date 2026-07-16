# Quick capture (⌃⇧⌘Space)

> **Kind:** concept
> **Sources:** Bubo/Composition/AppDelegate/AppDelegate.swift, Bubo/Composition/AppDelegate/AppDelegate+QuickCapture.swift, Bubo/Presentation/Views/QuickCapture/QuickCaptureView.swift, Bubo/Presentation/Views/Event/NewTaskView.swift, Bubo/Presentation/State/QuickCaptureBridge.swift
> **Last ingest:** 2026-07-16 (rev: line refs in `AppDelegate+QuickCapture.swift` bumped +1 — `installQuickCaptureHotkey` `:37`, local monitor `:47`, global `:62`, `spaceKeyCode` `:31`, `toggleQuickCapture` `:73`, RegisterEventHotKey comment `:27`)
> **Related:** [`../modules/app.md`](../modules/app.md), [`../modules/services.md`](../modules/services.md)

## What

A global hotkey (default ⌃⇧⌘Space) opens a small overlay anywhere in macOS to capture a new backlog task without switching focus.

## Flow

1. `AppDelegate` installs a pair of `NSEvent` monitors in `installQuickCaptureHotkey()` (`AppDelegate+QuickCapture.swift:37`): one **local** (`addLocalMonitorForEvents` at `:47`, fires when Bubo has focus, swallows the chord on match) and one **global** (`addGlobalMonitorForEvents` at `:62`, fires when another app is foreground; cannot consume the event so the chord must be unique). Key code `49` (Space) + `.control + .shift + .command` (`spaceKeyCode` at `:31`). Global monitor needs Accessibility permission to function. Carbon `RegisterEventHotKey` is **not** used — comment near `:27` notes it as an upgrade path if the chord becomes user-customisable.
2. On press, `toggleQuickCapture()` (`AppDelegate+QuickCapture.swift:73`) presents a borderless floating window hosting `QuickCaptureView` centred on the focused screen.
3. The user types a task. `QuickCaptureView` writes the buffer into `QuickCaptureBridge` (`Presentation/State/QuickCaptureBridge.swift`).
4. `⇧↩` opens the full `NewTaskView` pre-filled from the bridge buffer for detailed editing (deadline, recurrence, project, subtasks).
5. Plain `↩` commits directly via `BacklogService.addTask(...)` which persists to `BacklogTaskStore` and posts `.taskAdded`.

## Why a bridge

`QuickCaptureBridge` exists so the lightweight overlay (which should dismiss instantly on `↩`) and the full editor (which lives inside `MenuBarView`'s navigation stack) share state without coupling.

## Dismissal

The panel dismisses on `↩` (submit), `Esc`, a second hotkey press, and — since the 2026-07-16 HIG pass — on losing key-window status (click-outside), via `windowDidResignKey` in `AppDelegate.swift`'s `NSWindowDelegate` conformance. The backing `NSVisualEffectView` uses the `.popover` content material (HIG: HUD materials are reserved for control-free overlays).
