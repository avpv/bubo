# Optimizer JTBD · Roadmap

Companion to `optimizer-jtbd.md` (the JTBD framing) and `ROADMAP.md`
(the visual refactor). This file tracks the 7-step plan that takes the
Main Job from 7/10 → 10/10.

Main Job:
> Когда у меня больше задач и обязательств, чем времени в дне,
> я хочу доверить раскладку моего времени машине, которая знает мои
> правила, чтобы освободить голову от роли диспетчера и тратить её
> на саму работу.

The seven changes, by descending impact:

| # | Change | JTBD | Status | Effort |
|---|---|---|---|---|
| 1 | Delegation Contract | E1 + E2 | ✅ **Shipped** | done |
| 2 | "What I learned about you" | E1 + E2 + J5 | ✅ **Shipped** | done |
| 3 | Machine pushes back | Main + E1 | ⚠️ Component built, wiring pending | ~1 day |
| 4 | Multi-scenario picker | J4 | ⚠️ Component built, wiring pending | ~3 days |
| 5 | Auto-slot with undo | Main + J2 | ⏳ Not started | 3-4 days |
| 6 | Rules as a chip strip | E3 | ✅ **Shipped** | done |
| 7 | Ambient ghost-day | J6 | ⏳ Not started | 3 days |

---

## ✅ #1 — Delegation Contract — SHIPPED

**Path:** `Bubo/Presentation/Views/Settings/DelegationContractView.swift`

Plain-language "I will / I will never" contract surfaced at the top of
the Optimizer settings tab. Lists 6 explicit duties and 6 explicit
boundaries.

**Closes:** E1 (trust foundation), E2 (predictability statement).

---

## ✅ #2 — Optimizer Insights ("What I learned about you") — SHIPPED

**Path:** `Bubo/Presentation/Views/Settings/OptimizerInsightsView.swift`

Renders `IntentLearner.history`, `intentFrequency`, `temporalPatterns`
as three metric tiles (plans run / acceptance % / patterns count) and
a top-3 pattern list. Shows empty state with copy when the learner
hasn't accumulated data yet.

**Closes:** E1 (visible track record), E2 (calibrated trust), J5
(learner shows itself).

---

## ✅ #6 — Optimizer Rules Strip — SHIPPED

**Path:** `Bubo/Presentation/Views/Components/Common/OptimizerRulesStrip.swift`

Horizontal scroll chip row under the menu-bar header showing:
- 🕘 working hours window
- 📍 working days
- ⚡ peak energy hours
- 🔒 N locked
- 🙈 N excluded
- 🟢/🟠/🔴 capacity forecast

Wired in `MenuBarView+MainContent.swift` between WorldClock and the
Morning Brief. Tap routes to Settings > Optimizer.

**Closes:** E3 (rules are objects on the screen, not invisible defaults).

---

## ⚠️ #3 — Proactive Capacity Push-back — Wiring pending

**Component built:** `Bubo/Presentation/Views/Components/Banner/ProactiveCapacityNotice.swift`

The banner is ready. To activate it, the host needs three pieces of
wiring:

1. **A `@State` flag** in `MenuBarView` to gate visibility:
   ```swift
   @State var capacityNoticeDismissedForBacklogHash: Int? = nil
   ```
2. **A computed predicate** that fires only when:
   - `optimizerService.backlogService?.pending` is non-empty, AND
   - `optimizerRulesCapacityForecast` is `.over` or `.afterHours`, AND
   - The current pending workload hash ≠ `capacityNoticeDismissedForBacklogHash`
     (so dismissing it sticks until the user adds/removes a task)
3. **Render block** in `MenuBarView+MainContent.swift`, just above the
   morning brief block:
   ```swift
   if shouldShowProactiveCapacityNotice {
       ProactiveCapacityNotice(
           overloadDescription: capacityOverloadDescription,
           isAfterHours: optimizerRulesCapacityForecast == .afterHours,
           onSpread: { Task { await executeRequest(.scheduleBacklog) } },
           onDeferLeast: { deferLeastUrgentPending() },
           onDismiss: {
               capacityNoticeDismissedForBacklogHash = currentPendingHash
           }
       )
   }
   ```

The `deferLeastUrgentPending()` helper needs to:
- pick `optimizerService.backlogService?.pending.sorted(by: priority)` last item
- call `optimizerService.backlogService?.updateTask` with deadline +1 workday

**Closes:** Main Job (machine pushes back, not silent), E1 (active
delegate).

---

## ⚠️ #4 — Multi-Scenario Picker — Wiring pending

**Component built:** `Bubo/Presentation/Views/Components/Common/ScenarioPickerBar.swift`

Includes both the picker bar UI and `ScenarioTradeOffComposer` (pure
function for "deadlines first / focus protected / earliest finish"
phrasing from `objectiveBreakdown`).

The component is ready. To activate it:

1. **Surface state in `MenuBarView`:**
   ```swift
   @State var scenarioPickerActive: Bool = false
   @State var scenarioPickerSelectedID: String = "current"
   ```
2. **Build `[ScenarioPick]` from `optimizerService.scenarios`:**
   ```swift
   var scenarioPicks: [ScenarioPick] {
       let current = ScenarioPick(
           id: "current",
           label: "Current",
           tradeOff: "your real schedule",
           scenario: nil
       )
       let alternatives = optimizerService.scenarios.enumerated().map { idx, s in
           ScenarioPick(
               id: s.id.uuidString,
               label: "Plan \(["A","B","C","D","E"][idx % 5])",
               tradeOff: ScenarioTradeOffComposer.tradeOff(for: s, peers: optimizerService.scenarios),
               scenario: s
           )
       }
       return [current] + alternatives
   }
   ```
3. **Show the bar when scenarios.count > 1:** Render `ScenarioPickerBar`
   above the timeline once a Plan returns multiple scenarios.

4. **Ghost-rendering hook:** When `scenarioPickerSelectedID` ≠ "current",
   `MenuBarView+DayGroup` should render the picked scenario as ghost
   events instead of the real ones. Reuse the existing
   `backlogCoordinator.ghostSlot` plumbing — it already knows how to
   draw translucent blocks.

5. **Apply hook:**
   ```swift
   onApply: { scenario in
       Task {
           await optimizerService.applyScenario(scenario, reminderService: reminderService)
           toastState.showSuccess("Applied Plan \(label)", ...)
       }
   }
   ```

**Closes:** J4 (the single biggest gap — Pareto front pluralism).

---

## ⏳ #5 — Auto-Slot on Backlog Add — Not started

The plan:

1. Add a Setting toggle: `Auto-slot new tasks` (off by default).
2. Hook into `BacklogService.addTask` or its observer to detect new
   pending tasks.
3. When enabled, call `FreeSlotFinder.nextSlot(matching:in:workingHours:)`
   to find the next-fit slot.
4. Provisionally update the task's `scheduledDate` AND surface a long-
   duration toast (12 s) with Undo. If the user clicks Undo, revert.
   If 12 s pass without action, mark provisional → real.

Acceptance criteria:
- Off by default (opt-in for users who built trust).
- Slot decision must be deterministic and explainable (one-liner in toast).
- Cancellable in the undo window (12 s).
- Skips when forecast is `.over` / `.afterHours` (route to #3 instead).

**Effort:** 3-4 days.

---

## ⏳ #7 — Ambient Ghost Day — Not started

The plan:

1. When `OptimizerService.shadowProposal != nil` AND
   `shadowProposalUpdatedAt` is within 5 minutes:
   - Render the proposal's `ScheduleScenario.toCalendarEvents()` as
     translucent blocks on the day timeline.
   - Opacity = 0.30 by default.
   - Bump to 0.60 when hovering on the "Plan day" CTA.

2. The rendering hook lives in `MenuBarView+DayGroup`'s
   `dayGroupSection` — extend the existing event list interleaving to
   carry an optional "ghost overlay" pass after the real events.

3. Visual treatment: same `EventStripe` shape but with reduced opacity,
   diagonal hatch fill on the body, and a small `sparkles` glyph in
   the trail position.

Acceptance criteria:
- Ghost blocks must never intercept taps (use `.allowsHitTesting(false)`).
- Reduce Transparency replaces translucency with a 1 pt dashed border.
- Reduce Motion drops the entry transition.

**Effort:** 3 days.

---

## Suggested commit order for follow-up sessions

Each commit ideally lands in an environment with `swift build`:

1. **#3 wiring** (1 day) — small, all in `MenuBarView+MainContent` +
   `MenuBarView.swift`.
2. **#4 wiring without ghost layer** (1 day) — render the picker bar,
   wire Apply, leave ghost rendering for #7.
3. **#7 ghost-day** (3 days) — closes both J6 and gives #4 its ghost
   layer.
4. **#5 auto-slot** (3-4 days) — the heaviest, can wait until trust
   foundation (#1+#2+#6) has had user feedback.

After this, Main Job should test at **9.5/10**. The remaining 0.5
points are polish: hover effects on the rules strip, EOD review with
the machine, weekly planning, and the menu-bar density bar from the
prototype's bonus section.
