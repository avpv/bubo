# Body-split plan: MenuBarView & BacklogFullscreenView

> **Kind:** architecture
> **Sources:** Bubo/Presentation/Views/MenuBarView.swift, Bubo/Presentation/Views/BacklogFullscreenView.swift
> **Last ingest:** 2026-05-11
> **Related:** [`layered-structure.md`](layered-structure.md), [`../modules/views.md`](../modules/views.md)

This is an executable plan. Run it on a machine with `swift build`. Each
sub-View extraction is one PR; never bundle two. Verify per PR by
building and running the popover end-to-end before the next extraction.

## Why this plan exists

`MenuBarView.swift` (3256 L) and `BacklogFullscreenView.swift` (2026 L)
are the two biggest views in the app. They are not bugs — they work —
but they slow onboarding and produce nasty merge conflicts. The 2026-05
refactor sweep extracted every nested type out and trimmed -82 L; the
remaining bulk is one giant `var body: some View` per file with
~10 `private var ... : some View` and `@ViewBuilder` helpers feeding it.

Splitting `body` is the right next step. It cannot be done blind:
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

## MenuBarView — extraction candidates

`MenuBarView.swift` has these private `some View` members. Lines are
current as of 0ad5b36; they will shift after the first extraction —
re-grep after each PR.

| Line range | Member | Lines | Reads (sketch) | Risk | Recommended PR |
|---:|---|---:|---|---|---:|
| 912–940 | `loadMoreDaysButton` | 30 | `extraDaysShown` (`@State`), `skin`, `DS` | **Low** | 1 |
| 1928–1953 | `statusIndicators` | 27 | `networkMonitor`, `reminderService.isSyncing`, `skin` | **Low** | 2 |
| 2110–2195 | `emptyState` | 87 | `skin`, callbacks (`onAddEvent`, `onOpenCommandPalette`) | **Low-Med** | 3 |
| 2238–2314 | `colorFilterBar` | 78 | `colorFilter` (`@State`), `freeSlotFilter` (`@State`), `reminderService.eventsByDay` | **Med** — two state bindings | 4 |
| 1233–1250 | `nowNextLine` | 19 | `reminderService`, `nowTick` | **Low** | 5 |
| 3149–3255 | `footerActions` | 107 | many: navigation `@Binding`, services, palette context | **Med-High** — multiple bindings | 6 |
| 2339–2480 | `eventList` | 143 | day grouping, `eventsByDay`, `extraDaysShown`, scroll proxy, filters | **High** — too many props; refactor before extracting | 7 |
| 1644–1925 | `mainContent` | 282 | almost everything | **Highest** — leave for last, splits naturally only after the leaves above are out | 8 |

ViewBuilder functions to consider after the var-based ones:

| Line range | Function | Lines | Notes |
|---:|---|---:|---|
| 879–910 | `nowMarkerRow(_ stamp: Date)` | 32 | Pure date → row. Low risk. Could be a `View` struct or stay as a function. |
| 942–1018 | `dayNavCluster(scroll: ScrollViewProxy)` | 77 | Reads navigation `@State`. Med risk. |
| 2482–2884 | `dayGroupHeader(_:)` | ~400 | Massive. Don't touch until `eventList` is out. |
| 2886–2960 | `collapsedEventsHeader(for:)` | ~74 | Reads disintegration, hover state. Med risk. |

### PR 1 — Extract `LoadMoreDaysButton`

The cleanest one. The button writes one piece of state (`extraDaysShown`)
and reads only DesignSystem tokens and `skin`. Use a closure to push the
write back to the parent.

```swift
// New file: Presentation/Views/Components/LoadMoreDaysButton.swift
import SwiftUI

struct LoadMoreDaysButton: View {
    let onLoad: () -> Void
    @Environment(\.activeSkin) private var skin

    var body: some View {
        Button(action: {
            Haptics.tap()
            onLoad()
        }) {
            // ... same HStack as today
        }
        .buttonStyle(.borderless)
        .help("Show another week of upcoming days")
        .accessibilityLabel("Load more days")
    }
}
```

In `MenuBarView.swift`, replace the call with:

```swift
LoadMoreDaysButton {
    withAnimation(DS.Animation.smoothSpring) {
        extraDaysShown = min(Self.extraDaysCap, extraDaysShown + 7)
    }
}
```

Verify: build, open popover, scroll to the end of the day list, tap
the footer, see 7 more days appear with the spring animation.

### PR 2 — Extract `StatusIndicators`

Reads `networkMonitor.isConnected` and `reminderService.isSyncing`, both
`@Observable`. Pass both services as `let` properties; the new struct's
body observes them the same way the parent body does.

```swift
struct StatusIndicators: View {
    let networkMonitor: NetworkMonitor
    let reminderService: ReminderService
    @Environment(\.activeSkin) private var skin
    // ... same HStack
}
```

### PR 3 — Extract `EmptyState`

87 lines but mostly static layout. Takes callbacks for "add event" and
"open command palette" and a couple of strings. No `@Binding`. Good
intermediate target.

### PR 4 — Extract `ColorFilterBar`

Now we hit `@Binding`. The bar both reads and writes `colorFilter` and
`freeSlotFilter`. Pass them as `@Binding`:

```swift
struct ColorFilterBar: View {
    @Binding var colorFilter: EventColorTag?
    @Binding var freeSlotFilter: FreeSlotFilter
    let availableColors: [EventColorTag]
    @Environment(\.activeSkin) private var skin
    // ...
}
```

Call site:

```swift
ColorFilterBar(
    colorFilter: $colorFilter,
    freeSlotFilter: $freeSlotFilter,
    availableColors: Array(usedTags).sorted(by: { $0.rawValue < $1.rawValue })
)
```

Verify: tap a color chip, list filters; tap "Only free", grid hides
event rows; tap again to clear.

### PR 5 — Extract `NowNextLine`

Tiny, reads `nowTick` and `reminderService`. Trivial.

### PR 6 — Extract `FooterActions`

Multiple bindings (`navigation`, `paletteContext`) plus service
references plus callbacks. Stretches the rules — consider whether to
split into two structs (`FooterLeading`, `FooterTrailing`) instead of
one large `FooterActions`.

### PR 7 — Refactor `eventList` before extracting

`eventList` is too coupled — day grouping, scroll proxy, filters,
extras counter, ghost overlay, all in 143 lines. Two-step approach:

1. **Pre-step PR**: pull the day-grouping logic into a `private func`
   that returns `[(date: Date, items: [MenuBarDayListItem])]`. No
   View extraction — just reshape the helper API.
2. **Extract PR**: now `EventList` takes the pre-shaped array and
   renders. Bindings stay on the parent.

### PR 8 — `mainContent` last

By the time PR 1–7 land, `mainContent` is small enough that its
extraction is a paste-and-rename, not a refactor.

## BacklogFullscreenView — extraction candidates

| Line range | Member | Lines | Reads (sketch) | Risk | Recommended PR |
|---:|---|---:|---|---|---:|
| 1559–1574 | `tombstones` | 17 | `backlogService`, `expandFrozen` `@State` | **Low** | 1 |
| 1141–1171 | `hotKeyBindings` | 32 | event handlers + selection bindings | **Low** — pure keyboard wiring | 2 |
| 903–926 | `filterChipsRow` | 25 | filter `@State` bindings | **Low** | 3 |
| 813–837 | `smartFilterRow` | 25 | similar to above | **Low** | 4 |
| 544–567 | `etaChip` | 23 | `backlogService`, `settings` | **Low** | 5 |
| 693–750 | `activeFilterSummaryRow` | 59 | filter `@State` + summary computation | **Med** | 6 |
| 568–620 | `smartActionsRow` | 54 | optimizer suggestion `@Observable`, callbacks | **Med** | 7 |
| 1604–1728 | `addTaskField` | 126 | text `@State`, parser, slot preview cache | **Med-High** — owns its own typing state | 8 |
| 1368–1489 | `bulkActionsToolbar` | 123 | multi-select state, callbacks | **Med-High** | 9 |
| 987–1086 | `mainContent` | 100 | almost everything | **High** | 10 |

The `private func` ViewBuilders here are smaller helpers — extract
opportunistically with their parent section, not as separate PRs:

| Function | Used by |
|---|---|
| `suggestionBanner(_:)` | `smartActionsRow` |
| `projectChip(_:)`, `colorChip(_:)` | `filterChipsRow` |
| `row(for:hotKey:proposedSlot:)` | `mainContent` |
| `kbdHint(key:label:)` | bulk actions / hot-keys |

## Per-PR template

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

## Per-PR verification checklist

Before merging each PR:

- [ ] `swift build` clean
- [ ] `swift test --filter OptimizerTests` clean
- [ ] App launches without crash
- [ ] The extracted subview renders identically (eyeball)
- [ ] Every state the subview reads still updates the view
- [ ] Every state the subview writes still propagates to siblings
- [ ] Accessibility labels and `.help()` tooltips preserved
- [ ] No new warnings in the build log

## What to do when something breaks

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

## Tracking

Open a parent tracking issue with this plan linked, and check off each
PR as it merges. Re-grep line numbers after every merge: extractions
shift everything below.

After all 8 + 10 = 18 PRs land:

- `MenuBarView.swift` should be ~500–800 lines (`var body` + state
  declarations + a few orchestration `private func`s).
- `BacklogFullscreenView.swift` should be ~400–700 lines.
- 18 new files under `Presentation/Views/Components/`.

That's the realistic target. 9.5/10 territory.
