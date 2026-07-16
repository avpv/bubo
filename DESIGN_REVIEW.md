# Design Review — Design System × Skins × Backgrounds

Trigger (2026-07-16): live screenshot — System skin on a blue wallpaper.
The popover reads as blue-on-blue monochrome: accent countdowns invisible,
«Today» renders as a heavy dark saturated band, chips washed out, and the
accent color no longer means anything. Owner's verdict: «скины очень
похожи и многие очень ужасны». This review traces every symptom to code
and assesses all three layers. Companion docs: `UX_AUDIT.md` (flows),
`HIG_COMPLIANCE.md` (conventions). This one is about **beauty**.

## TL;DR

The screenshot is not a tuning miss — it is three structural problems
meeting in one frame:

1. **Accent is devalued.** §7 says accent marks the primary CTA,
   selection, and «now» — but at rest the main screen paints ~8 element
   types in accent (every Join, Add, every countdown, «Today» ×2,
   free-slot «+», shelf link). Nothing reads as primary.
2. **The legibility contract is luminance-only.** `BackdropLegibility`
   guarantees a 3:1 *luminance* floor against the *average* canvas color.
   It has no hue term: a blue accent over a blue wallpaper is «passed»
   after being blended toward white — producing the pale monochrome. The
   scrim turns off exactly in the saturated mid-blue danger zone.
3. **The skins are one template with 15 hues.** All seven stylistic axes
   the format supports (button style/shape, font face/weight, badge,
   separator, gradient geometry) are set to the same value in all 15
   JSONs. Only hue moves — hence «все похожи».

---

## A. Screenshot — symptom → root cause

| Symptom | Root cause |
|---|---|
| Countdowns «in 2 h 19 min» invisible | `EventRowView.swift:606-608` paints them in `skin.accentColor` on every non-Classic skin; the backdrop-adapted accent is blue-blended-toward-white (`BackdropLegibility.swift:84-98`) — passes the luminance floor, but no chroma separation from the blue canvas, and rows sit on the raw canvas (no platter, `MenuBarView+MainContent.swift:411-412`). |
| Heavy dark «Today» band | `DaySectionView.swift:77` hard-codes `.regularMaterial`; the wallpaper forces `.dark` scheme (`BackdropLegibility.swift:148-151`), and a dark vibrant material over a saturated wallpaper dims but **never desaturates** → dark saturated stripe. Header/footer use `.thin`, so chrome stacks two material weights + canvas washes = tonal ladder. |
| Header/world-clock washed out | Translucent white label colors (`labelColor`/`secondary`/`tertiary`) over a light `.thin` frosted blue; the tertiary machine-hint world clock is the worst case (`WorldClockStripView.swift:208-209`). |
| Free-slot «+», Plan/Focus chips illegible | «+» = accent fill at 0.25 opacity + accent glyph on raw canvas (`FreeSlotRow.swift:263-269`); quiet chip = primary-text fill at 0.08 + 0.10 stroke (`Chip.swift:127,135-136`); Focus idle = secondary text on transparent capsule (`FreeSlotRow.swift:221-225`). Translucent fills fall through to the canvas — the «text contrasts against the button fill» model only holds for opaque fills. |
| Everything blue | System skin's accent **is** the system blue, and its `auto` wallpaper paints the canvas from the skin's own accent tints (`WallpaperBackgroundLayer.swift:80-92`) — hue collision by construction. |

**Found bug:** `System.json` / `Classic.json` use gradient stops
`accentC20`/`accentC05` that `CustomSkinLoader.swift:230-238` doesn't
parse — they fall through to **full-opacity accent**. Classic hides it
(`style:"clear"`); System renders an over-saturated accent wash.

## B. Design system — why it doesn't feel «дорого»

1. **Accent economy is broken in code, honored only by chips.** Accent
   inventory at rest: Join buttons (primary gradient style per row!),
   Add, per-row countdowns, sticky «Today» eyebrow+title, day-nav
   «Today», free-slot «+», shelf «All tasks →». Meanwhile the one thing
   §7 reserves accent for — «now» — is rendered **orange**
   (`EventRowView.swift:573-581`). The chip system (`Chip.swift:119-127`)
   is the only §7-compliant emphasis model.
2. **Three-material chrome ladder.** Header/footer `.thin` + tint wash,
   action rail and rows on the washed canvas, sticky day header
   `.regularMaterial`, platters `.ultraThin`. Native macOS (Notification
   Center model, own §11): **one** material plane, hairlines, no tonal
   banding.
3. **2015-era decoration.** Gradient primary buttons + white «shine»
   stroke + accent glow shadows (`DesignSystem.swift:408-451, 499-505`),
   glassmorphism platter border with `.plusLighter`
   (`BuboSkin.swift:183-199`), scale-bounce on press/hover/drag/entrance
   everywhere. Modern macOS primaries are flat solid accent, neutral
   single-layer shadows, opacity feedback.
4. **Contrast below floors by construction.** machineHint = tertiary over
   wallpaper; chip strokes 0.10–0.25; day-summary/calendar captions
   tertiary. None gated on `reduceTransparency`/`colorSchemeContrast`
   at the token level.
5. **Mixed shape grammar on one screen.** Capsule (Join/Add/chips) +
   circle («+» disk) + flat rectangles (rows) + rounded-18 (cards) +
   rounded-14 (shell); `buttonShape` is even skin-authorable, so the
   grammar isn't guaranteed.

## C. Skins — one outfit, fifteen hues

- **Identical in all 15 JSONs:** `buttonStyle:solid`, `buttonShape:capsule`,
  `fontWeight:regular`, `fontDesign:default`, `badgeStyle:tinted`,
  `separatorStyle:subtle`, linear top→bottom gradient, `barTintOpacity:0.06`,
  `platterTintOpacity:0.04`. Unused axes: glass/gradient buttons,
  roundedRect/rectangle shapes, rounded/serif/mono faces, filled/outlined
  badges, accent/system/none separators, radial gradients, opacity ranges.
  Because every skin is `solid`, the authored `secondaryAccent`/
  `buttonSecondaryAccent`/`buttonTint` fields are **dead weight** — they
  render only in preview thumbnails.
- **Clusters:** blue ×7 (Classic, System, Apple, Ocean, Arctic, Midnight,
  WinXPBlue — Ocean/Arctic share a byte-identical `secondaryAccent`);
  gray ×2 (Graphite ≈ WinXPSilver); green ×2 (Sage ≈ WinXPOlive);
  warm-red ×2 (Crimson ≈ RoseGold). The «Luna» trio is retro in name
  only — capsules, SF Pro, tinted badges.
- **Semantic collisions (§7):** Crimson `#C0453B` ≈ destructive red;
  RoseGold `#C06B60` ≈ the *urgent* desaturated red; Sierra `#B8823C` ≈
  warning orange; WinXPBlue's green secondary ≈ success.
- **Contrast failures:** Graphite `#9090A8` ≈3.1:1 and Sierra `#B8823C`
  ≈3.3:1 vs white — solid-button labels fail AA.
- **Dark mode:** Arctic/RoseGold/Sierra force light regardless of system
  dark; the format can't express per-mode recolors at all (single
  `barTint`/`platterTint` values).

## D. Backgrounds — a luminance system asked to solve a hue problem

- The contract reduces the canvas to **average color + WCAG luminance**
  (`BackdropLegibility.swift:50-66,132-143`). Structural blind spots:
  no hue/ΔE term; mean-only sampling (gradient tops/bottoms diverge from
  the mean the sticky header scrolls across); scrim fires only in a
  narrow mid-luminance band — Cobalt/Denim/Monterey/Catalina get **no
  scrim**; a neutral scrim can't desaturate anyway; materials inherit
  wallpaper chroma under the forced scheme; adaptation samples the raw
  canvas while content actually sits on materials.
- Catalog (15×4 + none/auto) carries **no metadata** — no dominant hue,
  luminance band, or saturation; live wallpapers share one faked
  near-black constant (`BackdropLegibility.swift:125-128`). The whole
  cool family (blues, purples, greens) reproduces the screenshot for a
  matching skin accent.
- `auto` wallpaper for accent-token skins paints the canvas in the
  skin's own accent → the default install maximizes the collision.

---

## Recommendations (priority order)

R1–R3 are the «beauty» core; R4–R8 are the polish; S/W are catalog work.

- **R1. Reclaim accent.** — **landed 2026-07-16.** Join → new `.tinted`
  button role (accent text on translucent accent fill, no shadow);
  countdowns → neutral secondary on all skins; sticky day-header title →
  primary label; the Now pill switched from warning-orange to accent —
  «now» is what §7 reserves accent for. At rest the accent now belongs
  to: footer Add, the Now pill, selection, and small interactive links.
- **R2. Flat modern buttons.** — **landed 2026-07-16.** `.gradient`
  buttonStyle renders flat solid (case kept for JSON compat); white
  shine stroke removed from filled buttons (hairline kept on
  material-backed roles); primary's accent glow shadow → neutral
  `resolvedShadowColor`; the alert's hero Join flattened too.
- **R3. One material plane.** — **landed 2026-07-16.** Sticky day header
  uses the same `skinBarBackground` as header/footer (was
  `.regularMaterial` — the dark band); the accent surface-tint wash is
  skipped entirely whenever a wallpaper owns the canvas (was ×0.4).
- **R4. Opaque plates for accent-bearing controls** on the canvas
  («+», chips, countdown when wallpaper active) — make the «contrast
  against the fill» model true.
- **R5. Hue-aware legibility.** — **landed 2026-07-16.**
  `readableAccent` detects accent-hue ≈ canvas-hue at saturation and
  raises its contrast floor to min(4.5, 95% of pole) so the accent
  separates decisively in luminance; `legibilityScrim` now also fires on
  canvas *saturation* (up to ~0.16 polar scrim), covering the
  Cobalt/Monterey-class wallpapers that previously received none.
  Verified by simulation: system-blue accent over Cobalt/Denim/Monterey
  clears 4.5:1 (was ~3:1); neutral canvases unchanged.
- **R6. Wallpaper metadata.** Author dominant hue / luminance band /
  peak saturation (+ gradient endpoints) per wallpaper; replace the
  faked live/pattern canvas constants; two-band sampling for gradients.
- **R7. Chip/hairline contrast floor.** — **partially landed 2026-07-16:**
  prominent/quiet chip strokes 0.10 → `borderIdle` 0.18. Still open:
  machineHint floor/plate over wallpapers.
- **R8. One shape grammar.** Fix `buttonShape` product-wide (drop the
  per-skin axis), reconcile capsule/circle/rect on the main screen.
- **S. Curate skins.** — **landed 2026-07-16.** Catalog is 15 → 9:
  Classic (default), System, Apple, Ocean, Midnight, Graphite, Sage,
  Lavender, Mulberry. Cut: Arctic, Crimson, RoseGold, Sierra, and the
  WinXP trio (hue-only duplicates; three sat on status-color bands) —
  removed IDs fall back to Classic. Each keeper now spends a distinct
  axis: Ocean = SF Rounded + filled badges; Midnight = glass buttons +
  semibold (the never-shipped `glass` style finally has a home);
  Graphite = accent darkened to #6E6E80 (AA button labels) + outlined
  badges + system separators; Sage = serif + accent deepened to #45804F
  (AA); Lavender = secondary re-picked off pink (#B58CF2); Mulberry =
  new warm magenta #A8447C (~320° — clear of destructive red, urgent
  red, and warning orange).
- **W. Fix the `accentC20`/`accentC05` parser bug.** — **landed
  2026-07-16:** tokens rewritten to the parser-supported
  `accentColor:0.2` / `accentColor:0.05` syntax in System.json and
  Classic.json (System no longer renders a full-opacity accent wash).
