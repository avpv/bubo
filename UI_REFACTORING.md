# UI Refactoring Blueprint

Working map for the full presentation-layer refactor. The interface has
become unmanageable in two coupled ways — **visually** (unpredictable
stacking of conditional bands, surfaces that drift apart) and **in code**
(god-view state, callback drilling) — and the second causes the first:
when every band wires its own state and padding, no one can predict what
a given popover open will look like.

Domain and Application layers are healthy and out of scope. This is
`Bubo/Presentation` only.

## Diagnosis (measured 2026-06-10)

| Symptom | Measurement |
|---|---|
| God-view | `MenuBarView`: 21 `@State` fields + 14 sibling extension files; `private` relaxed to internal so extensions can reach shared state |
| Callback drilling | `EventRowView`: 26 closure parameters · `BacklogTaskRow`: 24 · `BacklogFullscreenView`: 13. Adding one row action touches 3–4 layers |
| Logic in view bodies | `BacklogFullscreenView` computes capacity plans and merges GA shadow slots; `SmartActionsBar` runs the ranker — none of it unit-testable without rendering |
| No screen models | All state is view-local `@State`; every visual change is surgery on live wiring |
| Band drift | Status banners, suggestion rows, filter strips, summary pills each carried their own padding and show/hide rules; live builds kept surfacing surprise layouts (centred lone chip, clipped pills, floating boundary rows) |

## Target architecture

### 1. One screen model per screen (`@Observable`)

`MenuBarScreenModel`, `BacklogScreenModel`, `PaletteModel` — each owns
its screen's state and *all* derived computation (delegating math to the
existing pure `BacklogLogic` / ranker / forecast helpers). Views become
thin bodies that read the model and emit user intents. The 14
`MenuBarView+*` extensions collapse into the model plus a handful of
small view files.

### 2. Actions through Environment, not parameters

One actions object per domain, injected via `EnvironmentValues`:

```swift
struct BacklogRowActions {
    var complete: (BacklogTask) -> Void
    var edit: (BacklogTask) -> Void
    var schedule: (BacklogTask) -> Void
    var snooze: (BacklogTask, Int) -> Void
    // … every verb takes the task; rows carry zero wiring
}
```

Rows read actions from the environment. Adding a verb = one field in the
struct + one menu item in the row. Per-row *facts* (canMoveUp, hotKey)
stay as parameters — they are data, not wiring.

### 3. Screen scaffold — the visual contract as a type

`PopoverScreenLayout` with fixed slots, in fixed order, each at most one
band tall, with inter-band rhythm owned by the scaffold (children lose
their outer vertical padding):

```
header        // title block / PopoverHeader
actions       // exactly one chip rail (or empty)
status        // exactly one banner: offline > permissions > sync error
strips        // context strips: world clock, color filter, smart filter
content       // fills remaining height
footer        // exactly one footer bar
```

A screen that wants a second action rail or a stacked banner has to
fight the type system — drift becomes a compile-time argument instead of
a screenshot surprise.

### 4. PRINCIPLES.md

Code comments across the tree cite `PRINCIPLES.md §1/§2/§8`; the file
does not exist. Write it (one page: one verb per surface, one voice per
text role, bands ≤ 1 per slot, no information shown twice, accent
reserved for CTA/selection) and link it from `AGENTS.md` so future
agents and humans stop re-deriving the rules from comment archaeology.

## Stages

Each stage is one PR; the app builds and behaves identically (or better)
after each. **Every stage needs one macOS build + screenshot pass** —
this environment has no Swift toolchain, so visual acceptance is a human
step by design.

| # | Scope | Files (centre of blast radius) | Acceptance |
|---|---|---|---|
| 1 | `PRINCIPLES.md` + `BacklogRowActions` environment; `BacklogTaskRow`/`BacklogFullscreenTaskRow` drop ~17 of 24 closure params | `Components/Backlog/BacklogTaskRow*`, `Backlog/BacklogFullscreenView*` | Row behaviour identical; param count ≤ 7 |
| 2 | `BacklogScreenModel` absorbs filter/sort/selection/capacity state; `BacklogFullscreenView` < 250 lines | `Backlog/*` | Same screen, view is composition-only |
| 3 | `MenuBarScreenModel` absorbs the 21 `@State` fields; extensions fold in; navigation becomes a router enum on the model | `MenuBar/*` (14 files → ~6) | Popover behaviour identical |
| 4 | `PopoverScreenLayout` scaffold; both screens re-assembled on it; children stripped of outer vertical padding (single source of rhythm) | `DesignSystem/`, both screens, strip components | Screenshots: band order/spacing identical across screens |
| 5 | `EventRowActions` environment (26 → ≤ 8 params); Components/Common triage (27 files: regroup, delete dead) | `Components/Event/*`, `Components/Common/*` | Row behaviour identical; folder map in wiki |

Stage order is dependency order: actions (1) unblock the model (2);
MenuBar (3) reuses both patterns; the scaffold (4) lands last among the
big ones because it is pure layout and safest to verify when the wiring
underneath is already clean.

## Progress (2026-06-23)

Stages 1, 2, 5 — landed. Stage 3 — state absorption **done**:
`MenuBarScreenModel` now owns the popover's session state (`toastState`,
`scrollPositionID`, `listScrollY`, `showingQuickCapture`,
`optimizerBottomY`, `dayRolloverTimer`); the dead `dismissedBannerIds`
field is deleted. `MenuBarView` is down from 9 `@State` to 2 — `screen`
(the model) and `backlogCoordinator` (a shared injected dependency,
created in `init` and published via `\.backlogCoordinator`, deliberately
kept on the view rather than forced through the model). The
extension-file collapse landed two single-concern merges (AutoDefer →
Lifecycle, EventActions → EventRow), 10 → 8 files; the remaining files
are kept separate on purpose — forcing the aspirational ~6 would create
grab-bag files now that the state is centralised and each extension is a
clean, well-named concern.
Stage 4 —
scaffold adopted on both screens; the **outer-vertical-padding
consolidation is now done**: the per-screen nudges that caused drift
(`MenuBarView+MainContent` header/action-rail `.padding(.bottom, sm)`,
`BacklogFullscreenView` header `.padding(.top, xs)`) are removed, so
inter-band rhythm comes uniformly from each band's own chrome under the
spacing-0 scaffold (PRINCIPLES §2). Genuine frame insets stay at the
call site (Backlog's floating footer keeps `.padding(.bottom, md)`;
MenuBar's footer is an edge-pinned full-bleed bar with none).

**Still requires the human screenshot pass** (no Swift toolchain in the
sync environment, by design): open both popovers and confirm band
order/spacing read identically and nothing clips at the popover edge
(§10). If a gap reads too tight after the nudges came off, the fix is
local — re-add a single padding at that one call site, or push the
rhythm into the scaffold as an explicit `interBand` spacing token.

## Non-goals

- No redesign of features or flows (the 2026-06 redesign PR already did
  the information architecture; this refactor freezes behaviour).
- No new dependencies, no architecture frameworks — `@Observable` +
  `EnvironmentValues` are sufficient.
- Settings window and FullScreenAlert keep their current structure until
  the popover stages prove the pattern.
