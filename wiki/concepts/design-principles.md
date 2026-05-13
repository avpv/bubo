# Design principles (distilled for code review)

> **Kind:** concept
> **Sources:** docs/design/PRINCIPLES.md
> **Last ingest:** 2026-05-12
> **Related:** [`../modules/views.md`](../modules/views.md), [`skins-system.md`](skins-system.md)

## The eleven rules

Numbered for cross-reference in PR comments. Full text in `docs/design/PRINCIPLES.md`.

1. **One primary action per screen** — dominant visual weight; never two equally-prominent buttons.
2. **Density is respect** — utility UI should be compact, with sensible min hit targets.
3. **Microtypography** — curved quotes, em/en dashes, non-breaking spaces in copy.
4. **Modality** — inline by default. Dialogs only for branching destructive choices.
5. **Undo over confirmation** — for reversible actions, prefer a toast with undo over a confirm dialog. Implemented via `UndoService`.
6. **Motion conveys relationship** — animations explain causality; respect Reduce Motion.
7. **Semantic colour is meaning** — red / orange / green / yellow have fixed meanings (destructive, warning, success, attention). Skins must not override.
8. **Typography** — SF Rounded is the family. Body weight is the tuning knob.
9. **Direct manipulation** — drag > menu > button > dialog. Prefer the leftmost option that works.
10. **Skin boundaries** — skins change mood only (accent, tint, button weight, badge/separator style). Not layout, not materials, not semantics. See [`skins-system.md`](skins-system.md).
11. **Describe rule conflicts** — when two principles disagree on a design, name the tension in the PR. Don't paper over.

## Where this lives in code

- `Presentation/Views/DesignSystem/` — the `DS` namespace (sizes, spacing, fonts, animations) is the canonical source for tokens. Magic numbers in feature views are a smell.
- `Presentation/Views/Skins/BuboSkin.swift` — the only path through which skin-themable mood properties reach views.
- `Application/Undo/UndoService.swift` — implements principle 5.
- `Presentation/Views/Components/Banner/ToastView.swift` — the canonical undo surface.

## Linting note

When ingesting a UI change, check whether it introduces hard-coded colours (principle 7 / 10 violation) or hard-coded sizes (principle 2 / via `DS` violation). Flag in the wiki page for the affected view if so.
