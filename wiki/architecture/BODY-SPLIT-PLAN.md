# Body-split plan: MenuBarView & BacklogFullscreenView

> **Kind:** architecture
> **Sources:** Bubo/Presentation/Views/MenuBarView.swift, Bubo/Presentation/Views/BacklogFullscreenView.swift
> **Last ingest:** 2026-05-11
> **Related:** [`layered-structure.md`](layered-structure.md), [`../modules/views.md`](../modules/views.md)

This is an executable plan. Run it on a machine with `swift build`. Each
sub-View extraction is one PR; never bundle two. Verify per PR by
building and running the popover end-to-end before the next extraction.

## Status (2026-05-11)

| Track | Done | Deferred |
|---|---|---|
| **MenuBarView** | PR 1 (`LoadMoreDaysButton`), PR 2 (`StatusIndicators`), PR 3 (`EmptyState`), PR 4 (`ColorFilterBar`), PR 5 (`NowNextLine` — inlined), PR 6 (`FooterActions`), PR 7 pre-step (`MenuBarTimelineDay` + `timelineDays()`), PR 7 (`EventList`) | PR 8 (`mainContent`) |
| **Backlog** | PR 1 (`tombstones` — inlined), PR 2 (`BacklogHotKeyBindings`), PR 3 (`BacklogFilterChipsRow`), PR 4 (`BacklogSmartFilterRow`), PR 5 (`BacklogETAChip`), PR 6 (`BacklogActiveFilterSummaryRow`), PR 7 (`BacklogSmartActionsRow`), PR 8 (`BacklogAddTaskField`), PR 9 (`BacklogBulkActionsToolbar`) | PR 10 (`mainContent`) |

Current file sizes vs. plan target:

| File | At plan inception | After leaves | Original target | Realistic remaining bulk |
|---|---:|---:|---:|---|
| `MenuBarView.swift` | 3256 L | 2900 L | 500–800 L | ~280 L in `dayGroupSection` + ~400 L in tightly-coupled helpers / computed |
| `BacklogFullscreenView.swift` | 2026 L | 1321 L | 400–700 L | ~90 L in `mainContent` + capacity-section helpers / `row(for:hotKey:proposedSlot:)` |

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
| `dayGroupSection(_:)` (~280 L) | Reads ~15 services / @State fields, owns drag handling, ghost overlay, working-hours boundary rows, per-row callbacks. Extracting would still leave every dependency on the host. Real work here is breaking it apart at a finer grain, not relocating it. |
| `dayGroupHeader(date:events:)` | Three-arg pure function but called only by `EventList`; keeping it on the host avoids a second arg-passing layer. |
| `nowMarkerRow(_:)` | 32 L pure-date pure-function — small enough that hoisting adds more ceremony than it saves. |
| `collapsedEventsHeader(for:)` | Same calculus as `dayGroupSection` — short body but reads disintegration / hover @State. |

## BacklogFullscreenView — leaf extractions (done)

All nine landed; the `private func` ViewBuilder helpers
(`suggestionBanner(_:)`, `projectChip(_:)`, `colorChip(_:)`,
`row(for:hotKey:proposedSlot:)`, `kbdHint(key:label:)`) moved with
their owning sections opportunistically rather than as separate PRs.

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
- `MenuBarView.swift` shrank from 3256 L → 2900 L (-356 L).
- `BacklogFullscreenView.swift` shrank from 2026 L → 1321 L (-705 L).
- 16 new files under `Presentation/Views/Components/` plus
  `Presentation/Views/MenuBarTimelineDay.swift`.

The 500–800 / 400–700 line targets stay open. The next leg of work
isn't another `body` carve — it's decomposing `dayGroupSection`
(MenuBar) and `row(for:hotKey:proposedSlot:)` (Backlog) so a future
extraction has fewer dependencies to wire through.
