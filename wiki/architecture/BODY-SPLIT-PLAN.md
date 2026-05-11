# Body-split plan: MenuBarView & BacklogFullscreenView

> **Kind:** architecture
> **Sources:** Bubo/Presentation/Views/MenuBarView.swift, Bubo/Presentation/Views/BacklogFullscreenView.swift
> **Last ingest:** 2026-05-11 (rev: row-builder decomposition)
> **Related:** [`layered-structure.md`](layered-structure.md), [`../modules/views.md`](../modules/views.md)

This is an executable plan. Run it on a machine with `swift build`. Each
sub-View extraction is one PR; never bundle two. Verify per PR by
building and running the popover end-to-end before the next extraction.

## Status (2026-05-11)

| Track | Done | Deferred |
|---|---|---|
| **MenuBarView** | PR 1 (`LoadMoreDaysButton`), PR 2 (`StatusIndicators`), PR 3 (`EmptyState`), PR 4 (`ColorFilterBar`), PR 5 (`NowNextLine` — inlined), PR 6 (`FooterActions`), PR 7 pre-step (`MenuBarTimelineDay` + `timelineDays()`), PR 7 (`EventList`), per-row decompose (`eventRow(_:)`, `freeSlotRow(start:end:slotId:day:)` carved off `dayGroupSection`) | PR 8 (`mainContent`) |
| **Backlog** | PR 1 (`tombstones` — inlined), PR 2 (`BacklogHotKeyBindings`), PR 3 (`BacklogFilterChipsRow`), PR 4 (`BacklogSmartFilterRow`), PR 5 (`BacklogETAChip`), PR 6 (`BacklogActiveFilterSummaryRow`), PR 7 (`BacklogSmartActionsRow`), PR 8 (`BacklogAddTaskField`), PR 9 (`BacklogBulkActionsToolbar`), row-builder decompose (`setPreferredPeriod`, `snoozeTaskDeadline` named helpers) + lift (`BacklogFullscreenTaskRow` struct) | PR 10 (`mainContent`) |

Current file sizes vs. plan target:

| File | At plan inception | After leaves | After row decompose | Original target | Realistic remaining bulk |
|---|---:|---:|---:|---:|---|
| `MenuBarView.swift` | 3256 L | 2900 L | 2934 L | 500–800 L | `dayGroupSection` is now ~120 L (down from ~280 L); the carved-off `eventRow(_:)` (~190 L) and `freeSlotRow(...)` (~70 L) live next door on the host. The file ticks up slightly from new docstrings. |
| `BacklogFullscreenView.swift` | 2026 L | 1321 L | 1332 L | 400–700 L | `row(for:hotKey:proposedSlot:)` is ~36 L of pure argument-marshaling (down from ~50 L); the `BacklogTaskRow(…)` construction + focus chain now lives in `BacklogFullscreenTaskRow.swift` (96 L). |

The original 500–800 / 400–700 targets were aspirational and assumed
`mainContent` would shrink to a thin orchestrator once the leaves were
out. In practice `mainContent` is still ~300 L on MenuBarView and ~90 L
on Backlog because it wires every service, every callback, every
@State binding the leaves consume. Extracting it as the plan's
"paste-and-rename" PR would create a struct with a 20+-parameter init
and a 1:1 line cost on the host — see [Deferred PRs](#deferred-prs).

## Why this plan exists

`MenuBarView.swift` and `BacklogFullscreenView.swift` were the two
biggest views in the app. They are not bugs — they work — but they
slow onboarding and produce nasty merge conflicts. The 2026-05 refactor
sweep extracted every nested type out and trimmed -82 L; the
remaining bulk was one giant `var body: some View` per file with
~10 `private var ... : some View` and `@ViewBuilder` helpers feeding it.

Splitting `body` was the right next step. It could not be done blind:
SwiftUI `@ViewBuilder` inference, closure capture of `@State`,
`@Environment`, and `Binding` semantics surface only at compile time.
Hence this is a plan, not a commit.

## Ground rules

1. **One subview per PR.** No batching.
2. **Each PR must `swift build` clean and run the popover.** Eyeball the
   resulting view in the menu bar; click through every state the
   subview controls.
3. **Default parameter shape:** the new struct takes only what the
   helper reads — never the whole `MenuBarView`. Prefer `let`
   parameters; reach for `@Binding` only when the subview writes a
   parent `@State`.
4. **Keep visual output bit-identical.** Wrap the extracted block in
   the same modifiers it had inside the host body. No "cleanup" in
   the same PR.
5. **Don't extract helpers that build their result from many `@State`
   fields with no clear contract.** They'll need a refactor first.

## MenuBarView — leaf extractions (done)

All eight original candidates landed. The PR 7 pre-step pre-shaped
the per-day data into `MenuBarTimelineDay` (a file-scope struct
sibling to `MenuBarDayListItem`) so the per-day free-slot computation,
ghost placement, NOW-marker gating, and interleaving all run in a
single `timelineDays()` helper. PR 7 then carved the `ScrollView` +
`LazyVStack` + `pinnedViews: [.sectionHeaders]` chrome into
`EventList` under `Components/`; per-day rendering (`dayGroupHeader`,
`dayGroupSection`) stays on the host and flows in as `@ViewBuilder`
closures because those leaves still depend on dozens of host @State
fields and service callbacks.

PR 5 (`NowNextLine`) and Backlog PR 1 (`tombstones`) were "wrapper-
inline" PRs: the helper just forwarded into an already-existing
component, so the rule reduced to deleting the wrapper at the call
site (no new file).

ViewBuilder funcs that were considered but rejected:

| Function | Why kept on host |
|---|---|
| `dayGroupSection(_:)` (was ~280 L; now ~120 L after the per-row decompose) | Reads ~15 services / @State fields, owns drag handling, ghost overlay, working-hours boundary rows, per-row callbacks. Extracting the whole function would still leave every dependency on the host. Instead the per-row arms were carved into named host helpers — see "row-builder decomposition" below. |
| `dayGroupHeader(date:events:)` | Three-arg pure function but called only by `EventList`; keeping it on the host avoids a second arg-passing layer. |
| `nowMarkerRow(_:)` | 32 L pure-date pure-function — small enough that hoisting adds more ceremony than it saves. |
| `collapsedEventsHeader(for:)` | Same calculus as `dayGroupSection` — short body but reads disintegration / hover @State. |

### MenuBarView — `dayGroupSection` row-builder decomposition

The "next leg of work" called out at the bottom of this doc landed:
the `.event` and `.slot` arms of `dayGroupSection`'s switch were
extracted into named private `@ViewBuilder` helpers on the host. The
function now reads as a thin orchestrator — four one-line case arms
flanked by the working-hours boundary rows and the after-hours
marker.

| Helper | Lines | Notes |
|---|---:|---|
| `eventRow(_:)` | ~190 L | `EventRowView` + the `backlogCoordinator.isDraggingTask` collapse gate. Closures still capture host services and @State (no new file — the goal was to name the «event row» concern, not relocate every dep). |
| `freeSlotRow(start:end:slotId:day:)` | ~70 L | `FreeSlotRow` + the ghost-suppression gate. Absorbs the day-local `let hintSlotId = day.hintSlotId` and `let ghost = ghostForDay(day.date)` bindings since both only affected this arm. |

This pass also fixed a latent compile break introduced by the PR 7
pre-step: that commit moved `let ghost = ghostForDay(dayGroup.date)`
out of `dayGroupSection` into `timelineDays()` but the `.slot`
suppression check `if let ghost, ghost.start == start` was kept,
leaving no `ghost` in scope. The lookup is now back inside
`freeSlotRow`.

## BacklogFullscreenView — leaf extractions (done)

All nine landed; the `private func` ViewBuilder helpers
(`suggestionBanner(_:)`, `projectChip(_:)`, `colorChip(_:)`,
`row(for:hotKey:proposedSlot:)`, `kbdHint(key:label:)`) moved with
their owning sections opportunistically rather than as separate PRs.

### BacklogFullscreenView — row-builder decomposition + lift

Also part of the "next leg of work". Done in two steps:

1. **Decompose** the inline lambdas inside
   `row(for:hotKey:proposedSlot:)` into named host methods:
   - `setPreferredPeriod(_:on:)` — pulled out of the 3-line
     `onSetPreferredPeriod` block.
   - `snoozeTaskDeadline(_:byDays:)` — pulled out of the 7-line
     `onSnoozeByDays` block. Mirrors the bulk-defer path's per-task
     body — both branches now share the same anchor + add-days logic.

   After this step `row(for:)` is pure argument-marshaling — every
   callback is a one-liner.

2. **Lift** the `BacklogTaskRow(…)` construction + the
   `.focusable() / .focused(_:equals:) / .focusEffectDisabled()`
   modifier chain into a dedicated `BacklogFullscreenTaskRow` struct
   under `Components/`, co-located with `BacklogTaskRow` itself. The
   host's `row(for:hotKey:proposedSlot:)` is now a ~36-line struct
   construction site that bundles host @State / @FocusState / service
   reads into the new view's init.

The lift's API surface is wide (~25 stored properties on
`BacklogFullscreenTaskRow`) — that's the inherent cost of bundling
per-row callbacks for a row with this many interaction modes. The
plan called this calculus out as the reason PR 10 was deferred; for
the row builder the cost is bounded (one task, one row shape) and
gives a future per-row UX change a focused target.

## Deferred PRs

### MenuBarView PR 8 — `mainContent`

**Status:** deferred.

`mainContent` is ~300 L today. The plan called this a
«paste-and-rename» once the leaves were out, but in practice the body
reads:

- ~6 @Observable services (`reminderService`, `optimizerService`,
  `networkMonitor`, `settings`, `toastState`, `backlogCoordinator`)
- ~12 @State fields (`scrollPositionID`, `colorFilter`,
  `freeSlotFilter`, `paletteContext`, `showingQuickCapture`,
  `navigation`, `nowTick`, `rollForwardDismissedDay`, `extraDaysShown`,
  `listScrollY`, `initialSyncDataArrived`, `initialSyncTimeoutFired`)
- ~10 computed properties (`headerTitle`, `headerSubtitle`,
  `isScrolledFromTop`, `filteredEventsByDay`, `permissionBannerSpecs`,
  `shouldShowEndOfDayBanner`, `eodUnfinishedCount`,
  `todaysEventsForNowNext`, `pendingTaskCount`, `emptyStateSubtitle`,
  `calendarHasAccess`, `showSyncingState`, …)
- ~8 private funcs (`runQuickAction`, `dayNavCluster`,
  `carryUnfinishedToTomorrow`, `dismissEndOfDayBannerForToday`,
  `notifyScheduleChange`, `resolveEdit`, `handleDelete`, …)
- The `eventList` wrapper + `FooterActions` + `EmptyState` + the
  syncing-state vstack

A struct extraction would need 20+ stored properties to relay all of
this; the host would lose ~300 L but gain ~50 L of parameter wiring
plus a wide-API new file. Net maintainability win is unclear, and
diff cost during review is high.

**Better follow-up work:** decompose `dayGroupSection` (~280 L, the
biggest remaining single member on `MenuBarView`) into smaller
per-row builders rather than one switch statement that owns every
`EventRowView` callback. That's where real maintainability is left.

### BacklogFullscreenView PR 10 — `mainContent`

**Status:** deferred for the same reason as MenuBarView PR 8. The body
is shorter (~90 L) but still reads `visibleTasks`, `completedToday`,
`backlogService.frozen`, `optimizerService.shadowProposal`/
`workingHours`/`workingDays`, `BacklogScrollOffsetKey`, the
`row(for:hotKey:proposedSlot:)` helper (which itself has a wide
surface), the tombstone bindings, and `handleScrollOffset`. The
extraction would not noticeably shrink the host.

**Better follow-up work:** lift `row(for:hotKey:proposedSlot:)` into
its own struct (it sits in the same per-row place
`BacklogTaskRow` already lives — could share or compose with it).

## Per-PR template (reference, for any future extractions)

For every extraction, follow this template. It's mechanical on
purpose — deviations are where bugs hide.

1. **Read the helper** end-to-end. List every `self.X` reference.
2. **Classify each reference:**
   - Read-only `@Observable` service → pass as `let`.
   - Read-only `let`/computed → pass as `let`.
   - Read+write `@State` on parent → pass as `@Binding`.
   - `@Environment` → re-declare on the new struct.
   - A callback that mutates parent state → pass as a closure.
3. **Create the new file** under `Presentation/Views/Components/`.
4. **Copy the helper body** into the new struct's `var body`.
5. **Replace the call site** in `MenuBarView` / `BacklogFullscreenView`
   with the new struct's initializer.
6. **Delete the old helper.**
7. **`swift build`.** Fix any errors before moving on.
8. **Run the app.** Open the popover, exercise the feature.
9. **Commit. Push. PR.** One subview per PR.
10. **Update `wiki/modules/views.md`** with the new file row.

## Per-PR verification checklist (reference)

Before merging each PR:

- [ ] `swift build` clean
- [ ] `swift test --filter OptimizerTests` clean
- [ ] App launches without crash
- [ ] The extracted subview renders identically (eyeball)
- [ ] Every state the subview reads still updates the view
- [ ] Every state the subview writes still propagates to siblings
- [ ] Accessibility labels and `.help()` tooltips preserved
- [ ] No new warnings in the build log

## What to do when something breaks (reference)

- **"Cannot find type X in scope"** — the type was nested in the host
  struct. Either hoist it (like the 2026-05-11 sweep did with
  `MenuBarNavigation` et al.) or qualify the reference.
- **"Argument passed to call that takes no arguments"** — `@ViewBuilder`
  inference picked the wrong overload. Add an explicit type annotation
  on the return.
- **`@Binding` doesn't update** — you passed `someState` instead of
  `$someState` at the call site.
- **Closure capture of `@State` doesn't fire** — `@State` doesn't cross
  view boundaries; convert to `@Binding` and lift the source of truth.

## What NOT to do in these PRs

- Don't fix unrelated comments or rename other types in the same PR.
- Don't change the visual output — even a 1-pt padding tweak belongs
  in a separate PR.
- Don't extract two subviews at once "while you're in there."
- Don't introduce a new view-model layer here — that's its own
  decision (see the unresolved items in `wiki/log.md`).

## Outcome

- 16 leaf PRs landed (`LoadMoreDaysButton`, `StatusIndicators`,
  `EmptyState`, `ColorFilterBar`, `NowNextLine` inlined, `FooterActions`,
  `MenuBarTimelineDay` + `timelineDays()`, `EventList`,
  `BacklogTombstones` inlined, `BacklogHotKeyBindings`,
  `BacklogFilterChipsRow`, `BacklogSmartFilterRow`, `BacklogETAChip`,
  `BacklogActiveFilterSummaryRow`, `BacklogSmartActionsRow`,
  `BacklogAddTaskField`, `BacklogBulkActionsToolbar`).
- Per-row decomposition landed for both files:
  - **MenuBar:** `eventRow(_:)` (~190 L) and `freeSlotRow(...)` (~70 L)
    carved off `dayGroupSection`, which is now ~120 L (down from
    ~280 L). Includes a latent-build-break fix for the missing
    `ghost` binding that the PR 7 pre-step left behind.
  - **Backlog:** `setPreferredPeriod(_:on:)` /
    `snoozeTaskDeadline(_:byDays:)` named helpers replaced the
    non-trivial inline lambdas in `row(for:hotKey:proposedSlot:)`,
    then the `BacklogTaskRow(…)` + focus-chain construction was
    lifted into `BacklogFullscreenTaskRow` under `Components/`.
- `MenuBarView.swift`: 3256 L → 2900 L (leaves) → 2934 L
  (+34 L from new helper docstrings; the host's biggest method
  shrank from ~280 L to ~120 L).
- `BacklogFullscreenView.swift`: 2026 L → 1321 L (leaves) → 1332 L
  (+11 L from new helper methods; the row builder is 36 L of pure
  argument-marshaling, down from ~50 L).
- 17 new files under `Presentation/Views/Components/` plus
  `Presentation/Views/MenuBarTimelineDay.swift`.

The 500–800 / 400–700 line targets stay open. With the row-builder
decomposition done, the realistic next leg is either: (a) live with
the file sizes as-is — they read as a thin orchestrator over named
per-row helpers, which is the point of the original plan; or
(b) revisit the deferred `mainContent` PRs once a clear view-model
direction is set (see `wiki/log.md`).
