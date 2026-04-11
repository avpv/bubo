# Bubo Design Principles

Bubo is a native macOS utility that lives in the menu bar. Its design is
governed by two traditions that, taken together, cover almost every decision
a contributor will face:

- **Apple Human Interface Guidelines** — the platform contract. Bubo is a
  macOS app, and the operating system has opinions about colour, typography,
  materials, motion and accessibility. We honour them.
- **Ilya Birman's design tradition** (Bureau Gorbunov) — the editorial
  attitude. It answers questions that HIG leaves open: how dense should the
  UI be, when is a confirmation dialog a cop‑out, what does good
  microtypography look like, how aggressive can we be with undo.

HIG tells us what the platform expects. Birman tells us what a considered
product feels like. The rules below are the synthesis we commit to.

---

## 1. Hierarchy: one primary, the rest quiet

*HIG §Layout · Birman: "one dominant element per screen"*

Every screen has exactly one primary action. It is visually dominant — filled
background, accent colour, largest weight in the row. Secondary actions share
one subdued style and one side of the screen. A screen with two equally loud
buttons is a bug.

**In Bubo**: the menu bar footer has `Add` (primary) on the left. `Tasks` and
`More` share the right side with a single borderless style. Don't introduce a
third visually prominent button.

---

## 2. Density is respect for attention

*HIG minimum hit targets · Birman: "density is respect for attention"*

HIG gives minimum hit‑target sizes. Birman argues that extra padding beyond
the minimum steals attention from content. Both are right.

**Rule**: HIG minimums are a floor, not a target. Utility windows (menu bar
popover, settings) favour density. Controls stay at ≥ 28 pt height for
clickability; text lists pack tight. If a screen feels airy, it's probably
wasting pixels on a 360 pt popover that a user is glancing at.

---

## 3. Microtypography is not optional

*Birman §Microtypography*

HIG is silent on punctuation, so we defer entirely to Birman here. A product
that gets microtypography wrong feels amateur in a way most users can't
articulate but all of them notice.

Required:

- **Ellipsis**: `…` (U+2026), never three dots `...`. String `"Loading…"`, not
  `"Loading..."`.
- **Em/en dashes**: `—` (U+2014) in prose, `–` (U+2013) in numeric ranges
  like `13:00–13:45`. Never a hyphen `-` as a dash.
- **Non‑breaking space**: `\u{00A0}` between a number and its unit
  (`12\u{00A0}min`, `3\u{00A0}h`). Stops awkward line breaks.
- **Quotation marks**: `"…"` (U+201C/201D) around event titles in prose and
  toasts, never straight quotes `"..."`.
- **Minus sign**: `−` (U+2212) for numeric negatives like time zone offsets,
  never a hyphen.
- **Interpunct**: `·` (U+00B7) as a separator in compact strings like
  `5\u{00A0}of\u{00A0}7\u{00A0}·\u{00A0}in\u{00A0}15\u{00A0}min`.

We already have `DS.formatMinutes(_:)` and similar helpers. Use them.

---

## 4. Modality: inline by default, dialog only for branching choice

*HIG §Sheets + Alerts · Birman: "bad UI adds modes; good UI removes them"*

HIG allows sheets, alerts, confirmation dialogs. Birman says modes are where
UI goes to die. The synthesis:

- **Default**: edit and act inline. The backlog edits tasks in place. Event
  rows trigger actions via context menu. The command palette overlays
  without stealing focus.
- **Confirmation dialog**: allowed only when the user must *choose between
  multiple destructive outcomes*. Deleting a recurring event is the canonical
  example — "this occurrence" vs "entire series" — the dialog isn't asking
  "are you sure?", it's asking "which one?".
- **Alert**: reserved for errors the system needs to surface synchronously.
  Not for confirmations, never for celebrations.

---

## 5. Undo over confirmation

*Birman: "undo is faster than confirm" · HIG §Alerts (destructive actions)*

HIG tells us to confirm destructive actions. Birman argues the entire premise
is lazy: a good product lets you act and unact. Reconcile by asking what kind
of destruction it is.

- **Local, reversible**: undo toast. Deleting a local event, completing a
  task, rescheduling — all land in a toast with `Undo`. No confirm.
- **Destructive with branching**: confirmation dialog (see §4).
- **Genuinely irreversible or public**: confirm. Sending a message to another
  human, publishing, billing. Bubo rarely does any of these; when it does,
  confirm.

A `Button(role: .destructive)` that only needs undo does **not** need a
confirmation. The role colours it red; that's the signal.

---

## 6. Motion: HIG decides *when*, Birman decides *whether*

*HIG §Motion (Reduce Motion) · Birman: "animation should convey relationship,
not decorate"*

HIG is clear about respecting the Reduce Motion accessibility setting. Birman
asks a harder question: should this animation exist at all?

Two‑part rule:

1. **Should it exist?** If the animation shows *where an element came from
   or went to* (a list item sliding, a toast entering), keep it. If it
   exists to make the UI "feel alive" (staggered entrance, pulse, bounce,
   scale‑on‑hover without purpose), delete it.
2. **If it exists, is it motion‑aware?** Use
   `DS.Animation.motionAware(_:reduceMotion:)` or the `@Environment
   (\.accessibilityReduceMotion)` branch. A motionless fallback is mandatory.

Consequence: the product has **one** motion signature, not a palette. Skins
don't get to pick between "bouncy", "smooth" and "snappy" — the choice is
fixed globally so the product feels coherent regardless of the active theme.

---

## 7. Semantic colour is meaning, not decoration

*HIG §Colour · Birman: "semantic colours are not ornaments"*

Red means destructive. Green means success. Orange means warning. These
assignments exist in the user's head before they open Bubo; overriding them
per‑skin would be vandalism.

**Rule**: `destructive`, `success`, `warning` colours always come from the
system (`systemRed`, `systemGreen`, `systemOrange`). Skins can change the
accent and the mood; they cannot change what red *means*.

Corollary: never communicate state with colour alone. A status badge uses
colour *and* icon *and* label, so that users with colour‑vision differences
get the same information.

---

## 8. Typography: one scale, one design, one body weight

*HIG §Typography · Birman §Typographic rhythm*

HIG forbids custom typefaces in utility windows. Birman adds: a product picks
one scale and sticks to it. Consequences:

- **Font design**: SF Rounded across the entire app. No per‑skin override.
- **Body weight**: the only typography knob a skin can turn. Options:
  `regular`, `medium`, `semibold`, `bold`.
- **Headline weight**: derived from body weight, one step bolder. Skins
  don't set it.
- **SF Symbol weight**: derived from body weight (HIG: "match symbol weight
  to adjacent text weight"). Skins don't set it.
- **SF Symbol rendering**: always `hierarchical`. HIG recommends it for
  utility apps; we commit.

Type sizes come from the macOS text‑style system (`.caption2`, `.caption`,
`.subheadline`, `.headline`, `.title2`), not hand‑tuned point sizes. This
gets Dynamic Type for free.

---

## 9. Direct manipulation beats abstraction

*HIG §Drag and Drop · Birman: "direct > indirect"*

Ranking, best to worst:

1. Drag the thing onto the other thing. (Drag a backlog task onto a free
   slot on the timeline.)
2. Right‑click the thing, pick an action. (Context menu on an event row.)
3. Select the thing, click an action button in a toolbar.
4. Open a dialog that asks what to do, then confirms.

Every feature should try to live as close to (1) as possible. When we add a
new interaction, the question is not "how do we surface this button?" but
"what object is this an operation *on*, and can the user point at it?".

---

## 10. The skin system has boundaries

*This section captures the outcome of the Skin refactor and is the canonical
reference for what a skin may and may not change.*

A skin describes **mood**, not layout. The schema
(`Bubo/Skins/buboskin.schema.json`) is strict: unknown fields are rejected.

**A skin may change:**

- Identity (`id`, `displayName`, `author`).
- Accent and mood (`accentColor`, `prefersDarkTint`, `backgroundGradient`,
  `previewColors`, `secondaryAccent`).
- Subtle surface tints (`barTint`, `platterTint`, with their opacities).
- Button style (`gradient` / `solid` / `glass`) and shape (`capsule` /
  `roundedRect` / `rectangle`).
- Button foreground override for retro themes (`buttonColor`,
  `buttonAccentColor`, `buttonSecondaryAccent`, `buttonTint`).
- Body font weight.
- Badge style (`tinted` / `filled` / `outlined`).
- Separator style (`subtle` / `system` / `accent` / `none`).

**A skin may not change:**

- Semantic colours (red/green/orange) — see §7.
- Text colours — they come from system labels so Dark Mode and
  Accessibility settings always work.
- Materials (bar, platter, button) — uniform translucency is part of the
  product's identity.
- Shadow depth (radii, offsets, opacities) — derived once from
  `prefersDarkTint`, not per‑skin.
- Animation physics — one motion signature, see §6.
- Font design — always SF Rounded, see §8.
- Symbol rendering and weight — derived, see §8.
- Corner radii and spacing grid — defined in `DS`, applied globally.

If a new skin genuinely needs to break one of these boundaries, that's not a
schema change — that's a product decision. Open an issue.

---

## 11. When the rules disagree, describe the conflict

No set of principles survives contact with every screen. When two rules
point in different directions on a specific decision, the answer is not to
quietly pick one and pretend. The answer is to:

1. Name which principles are in tension in the PR description.
2. Explain what you chose and why.
3. Link this document so the reviewer can check your reasoning.

The principles are not a lint rule; they're a shared vocabulary for design
review.

---

## Quick reference for reviewers

When reviewing a UI change, work this checklist in order:

- [ ] One primary action, visually dominant? (§1)
- [ ] Minimum hit targets met *and* no wasted padding? (§2)
- [ ] Microtypography correct: `…`, `–`, non‑breaking spaces, curly quotes? (§3)
- [ ] Modal chosen for a real reason (branching destructive choice)? (§4)
- [ ] Destructive = undo toast unless it's truly irreversible or public? (§5)
- [ ] Every animation conveys a relationship *and* respects Reduce Motion? (§6)
- [ ] Red/green/orange used only in their semantic meaning? (§7)
- [ ] No hand‑tuned font sizes; SF Rounded; type styles from macOS? (§8)
- [ ] Best available level of direct manipulation? (§9)
- [ ] If touching skins: still within the boundaries of §10?
- [ ] If the rules disagreed, is the trade‑off explained in the PR? (§11)
