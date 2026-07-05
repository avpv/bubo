# Workflow Redesign — «One Timeline»

The 2026-07-05 direction from the product owner, in two constraints that
now function as design law for the presentation layer:

1. **«Миров больше нет» — Model A, one timeline.** Events, scheduled
   tasks, free slots and unscheduled work all live on ONE chronological
   canvas. The user never has to decide «which screen does this thing
   live on» during the daily loop.
2. **«Всё на одном экране = хаос» — one screen, one job.** One canvas
   does NOT mean one dashboard. At rest the main screen shows only what
   serves *now and today*: header, canvas, footer. Everything else is a
   layer one tap away, never a permanently stacked band.

Together: the timeline is the only world, and it must stay quiet.

## The target daily loop

```
capture ──▶ glance ──▶ plan ──▶ do ──▶ adjust
  ⌘N        popover     Plan     ✓ on   drag /
 Quick Add   opens      verb     rows   context
```

- **Capture** — the unified «Add» front door (landed, UX_AUDIT F8-B):
  free text routes to task or event by one rule; ⇧⌘N global capture.
- **Glance** — open the popover: today's canvas with events, scheduled
  tasks, free slots, and the **Unscheduled shelf** as the first block
  on the canvas (not a separate world).
- **Plan** — ONE machine verb. Its label adapts to the forecast («Plan
  day», «Schedule overflow · 3»); it opens the planner (palette — the
  single planner home the codebase already declares), which shows the
  proposal and applies with undo.
- **Do** — complete from the timeline rows; «now» is visually anchored.
- **Adjust** — drag blocks / shelf tasks onto slots; context menus for
  everything per-item.

What dies with the two-worlds model: the Backlog fullscreen as a daily
destination (it stays as a *management* layer — bulk ops, projects,
tombstones), planner verbs scattered as permanent chrome, and duplicate
renderings of the same fact on the resting screen.

## Layers (each = one job)

| Layer | Job | Entry |
|---|---|---|
| Canvas (main) | now + today + this week | opening the popover |
| Quick Add | capture a thought | «Add» / ⌘N / ⇧⌘N |
| Planner | review & apply the machine's proposal | «Plan» / ⌘K |
| Tasks management | bulk edit the list | «Tasks» footer link, shelf «All tasks» |
| Details forms | full editing of one item | ⇧↩ from Quick Add, row actions |

## Stages

Each stage is one PR; app builds after each; acceptance = macOS build +
screenshot pass (no Swift toolchain in the dev environment, by design).

| # | Scope | Status |
|---|---|---|
| R1 | **Unscheduled shelf on the canvas.** Collapsed one-line summary («Unscheduled · N · ~2 h») as the first block of the event list; expands in place to the top pending tasks; rows drag onto free slots (existing `BacklogTaskDrag` → `FreeSlotRow` path) and tap into the planner seeded with the task; «All tasks» hands off to the management layer. Revives the orphaned `TaskListExpansion` state machine (its inline host was deleted in the 2026-06 redesign — this is the root of the two-worlds split). | **landed 2026-07-05** |
| R2 | **Declutter the resting screen.** World-clock band → one quiet inline line in the header block (`WorldClockInlineLine`; the pill strip is deleted, styling lives in git history); colour-filter band → behind a filter glyph in the header's trailing cluster, visible only while the glyph is toggled OR a filter is active (an active filter must never hide — «no events» with an invisible cause is a trap). Supersedes the owner's earlier «keep the strips» choice; re-confirmed via the «продолжай» go-ahead after the trade-off was named. | **landed 2026-07-05** |
| R3 | **One Plan verb.** SmartActionsBar's hard/soft/calm chip rail collapses into a single adaptive «Plan» button (label from the forecast) opening the palette; ranked calm actions and presets live inside the palette only. Quick-capture anchor moves with it. | proposed |
| R4 | **Backlog fullscreen → management only.** Its planner verbs (Plan N pill, SmartActions row) reduce to one «Plan» handoff; screen keeps selection, bulk ops, freeze/tombstones, projects. | proposed |
| R5 | **Now-anchored header + polish.** Header leads with «now / next in X» (nowTick machinery exists); duplicate facts removed (UX_AUDIT F4); free-slot copy rounding (F7); form ergonomics (F9). | proposed |

## R1 implementation notes

- The shelf mounts as `EventList.leadingContent` — it scrolls WITH the
  canvas (it is content, not chrome), consistent with constraint 2.
- Shelf rows are `.draggable(BacklogTaskDrag)`; drops reuse
  `handleTaskDrop` unchanged. The coordinator's `beginDrag` visual
  pulses (day-collapse, ghost preview) are NOT wired from the shelf yet
  — `.draggable` exposes no drag-start hook; `handleTaskDrop` ends the
  session defensively so drops are correct without them. Follow-up:
  restore pulses via a custom drag preview or `onDrag` provider.
- Row tap seeds the planner (`MenuBarPaletteContext(seedTask:)`) — the
  palette already renders task-specific suggestions for that seed.
- Empty pending list ⇒ the shelf renders nothing (§2: an empty band is
  no band).
