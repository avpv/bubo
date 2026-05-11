# Undo

> **Kind:** concept
> **Sources:** Bubo/Application/Undo/UndoService.swift, Bubo/Presentation/Views/Components/Banner/ToastView.swift, docs/design/PRINCIPLES.md
> **Last ingest:** 2026-05-12 (rev: bounded-context restructure + mega-file split)
> **Related:** [`design-principles.md`](design-principles.md), [`../modules/views.md`](../modules/views.md), [`../modules/services.md`](../modules/services.md)

## What

Per PRINCIPLES §5 ("Undo over confirmation"), Bubo replaces "Are you sure?" dialogs with instant action + an undo toast. `UndoService` is the registry the toast reads from.

The header comment in `UndoService.swift:3–10` cites Birman's design principles as the source. The toast comment in `ToastView.swift:88` also references HIG undo guidance.

## Shape

`UndoService` (`Bubo/Application/Undo/UndoService.swift`) is `@MainActor @Observable`. Surface:

| Symbol | Where | Role |
|---|---|---|
| `lastAction: UndoAction?` | `UndoService.swift:16` | The most recent undoable action — drives the toast |
| `isShowingToast: Bool` | `UndoService.swift:19` | Toast visibility |
| `push(_ label:, duration: 5, undo: () -> Void)` | `UndoService.swift:24` | Register an action and show the toast |
| `performUndo()` | `UndoService.swift:42` | Run the closure and dismiss |
| `dismiss()` | `UndoService.swift:49` | Hide without undoing |
| `struct UndoAction { label, undo }` | `UndoService.swift:57` | Value type stored on the stack |

A single `dismissTask: Task<Void, Never>?` (`UndoService.swift:21`) auto-dismisses the toast after `duration` seconds; pushing a new action cancels the prior dismiss timer.

## How to use it

Any destructive or hard-to-undo UI action should push an undo entry instead of opening a confirm dialog. Pattern:

```swift
backlogService.complete(task)
undoService.push("Completed \"\(task.title)\"") {
    backlogService.uncomplete(task)
}
```

Five seconds is the default toast duration; pass `duration:` for actions that warrant longer (typically bulk operations).

## Toast surface

`Presentation/Views/Components/Banner/ToastView.swift` is the canonical surface — it renders the undo button when its `UndoAction` is non-nil (`ToastView.swift:9`) and lengthens the auto-dismiss for undo toasts (`:38`). Other toast varieties (status, info) reuse the same component without the undo affordance.

## Limits

- Stack depth is **one**. `push` overwrites `lastAction` — multi-step undo is not a feature. Repeated pushes lose the previous closure (the toast cancels its own dismiss timer, then the new label appears).
- Undo closures run on `MainActor` synchronously. Don't perform network I/O inside; queue work instead.
- The closure is retained until dismiss; capture only what you need to invert the action — large captures will keep state alive five seconds longer than necessary.

## Cross-references

- PRINCIPLES §5: prefer undo over confirmation for reversible destructive actions.
- Confirm dialogs are still appropriate for **branching** destructive choices (PRINCIPLES §4: Modality).
