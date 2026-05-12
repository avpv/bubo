# Quick capture (⌃⇧⌘Space)

> **Kind:** concept
> **Sources:** Bubo/Composition/AppDelegate.swift, Bubo/Composition/AppDelegate+QuickCapture.swift, Bubo/Presentation/Views/QuickCapture/QuickCaptureView.swift, Bubo/Presentation/Views/Event/NewTaskView.swift, Bubo/Presentation/Coordinators/QuickCaptureBridge.swift
> **Last ingest:** 2026-05-12
> **Related:** [`../modules/app.md`](../modules/app.md), [`../modules/services.md`](../modules/services.md)

## What

A global hotkey (default ⌃⇧⌘Space) opens a small overlay anywhere in macOS to capture a new backlog task without switching focus.

## Flow

1. `AppDelegate` installs a pair of `NSEvent` monitors in `installQuickCaptureHotkey()` (`AppDelegate+QuickCapture.swift:36`): one **local** (`addLocalMonitorForEvents` at `:46`, fires when Bubo has focus, swallows the chord on match) and one **global** (`addGlobalMonitorForEvents` at `:61`, fires when another app is foreground; cannot consume the event so the chord must be unique). Key code `49` (Space) + `.control + .shift + .command` (`spaceKeyCode` at `:30`). Global monitor needs Accessibility permission to function. Carbon `RegisterEventHotKey` is **not** used — comment near `:26` notes it as an upgrade path if the chord becomes user-customisable.
2. On press, `toggleQuickCapture()` (`AppDelegate+QuickCapture.swift:72`) presents a borderless floating window hosting `QuickCaptureView` centred on the focused screen.
3. The user types a task. `QuickCaptureView` writes the buffer into `QuickCaptureBridge` (`Presentation/Coordinators/QuickCaptureBridge.swift`).
4. `⇧↩` opens the full `NewTaskView` pre-filled from the bridge buffer for detailed editing (deadline, recurrence, project, subtasks).
5. Plain `↩` commits directly via `BacklogService.addTask(...)` which persists to `BacklogTaskStore` and posts `.taskAdded`.

## Why a bridge

`QuickCaptureBridge` exists so the lightweight overlay (which should dismiss instantly on `↩`) and the full editor (which lives inside `MenuBarView`'s navigation stack) share state without coupling.
