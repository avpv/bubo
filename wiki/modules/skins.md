# Module: Skins

> **Kind:** module
> **Sources:** Bubo/Presentation/Views/Skins/
> **Last ingest:** 2026-07-16 (rev: catalog curated 15 → 9 (DESIGN_REVIEW S). Cut as hue-only near-duplicates or semantic-color collisions: `Arctic`, `Crimson`, `RoseGold`, `Sierra`, `WinXPBlue`, `WinXPOlive`, `WinXPSilver`; added `Mulberry` (warm magenta `#A8447C`, off every status band). Keepers now spend distinct stylistic axes: Ocean = SF Rounded + filled badges, Midnight = glass buttons + semibold, Graphite = darkened accent `#6E6E80` (AA labels) + outlined badges + system separators, Sage = serif + deepened accent `#45804F`, Lavender secondary re-picked off pink (`#B58CF2`). `BuiltInSkinLoader.order` updated; removed IDs fall back to Classic via `SkinCatalog.skin(forID:)`. Also fixed: `accentC20`/`accentC05` gradient tokens in System/Classic were unparsed (rendered full-opacity accent) — rewritten as `accentColor:0.2`/`0.05`.) (prev rev: focused chrome subtraction. `MenuBarView+MainContent` lost the standalone «Optimize schedule» command bar — the eyebrow+title block is itself a Button now (Spotlight-style entry: tap or ⌘K), with the shortcut hint inline next to the title rather than as a nested filled pill. ColorFilterBar kept always-visible-when-events-exist: it carries the free-slot picker which is a primary affordance for «find me a free window today» and can't be hidden behind an active-filter chip without breaking that discovery. WorldClockStripView remains conditional on the user having cities configured (already correct). One chrome strip removed; the popover's existing VStack ordering preserved otherwise.) (prev rev: round 2 of structural rewrites. `GeneralTabView` migrated from `ScrollView { VStack { SettingsPlatter("X") { ... } } }` to native `Form { Section { ... } } .formStyle(.grouped)` — every row uses `Label(name, systemImage:)` (Apple Settings.app pattern), every setting wrapped in `Toggle` / `Picker` / `LabeledContent` / `Stepper` with proper label slots, version + GitHub link moved to a section `footer:` instead of two centred `Spacer()`-padded rows. `CloudSyncStatusSection` returns a `Section` directly so it composes inside the parent Form. `BacklogHeader` 7-control HStack split into a leading **title block** (eyebrow «BACKLOG» + ring + count + ETA) and a trailing **toolbar row** (smart-sort, plan, project-picker, fullscreen) — was a toolbar masquerading as a title, now they're separated like Apple's NavigationStack pattern. Smart-sort filled-circle background and plan-pill fill+stroke removed (single tinted glyph and single tinted capsule respectively — one surface each). Hover actions on `EventRowView` no longer slide-displace the row contents (`.move(edge: .trailing)` → `.opacity`); destructive `xmark` glyph stays secondary-tinted at rest and only turns red on explicit hover (Apple's «destructive controls stay quiet until reached for»). Inline-rename `TextField` shed its fill+stroke pair for a single accent-tinted focus ring (Finder rename idiom).
> **Related:** [`../concepts/skins-system.md`](../concepts/skins-system.md), [`views.md`](views.md), [`../concepts/design-principles.md`](../concepts/design-principles.md)

## Files

| File | Lines | Main types (line) | Role |
|---|---:|---|---|
| `SkinDefinition.swift` | ~545 | `enum SkinButtonStyle`, `enum SkinButtonShape`, `enum SkinFontWeight`, `enum SkinFontDesign` (new), `enum SkinBadgeStyle`, `enum SkinSeparatorStyle`, `struct SkinDefinition`, `struct SkinGradient`, `enum SkinCatalog` | Full Swift schema for a skin. Button style: `.solid`, `.gradient`, `.glass`. Button shape: `.capsule`, `.roundedRect`, `.rectangle`. Font design: `.rounded` (default — SF Rounded), `.default` (SF Pro Text/Display, used by the Apple skin), `.serif`, `.monospaced` |
| `CustomSkinLoader.swift` | 526 | `struct CustomSkinJSON` (`:36`), `struct JSONColor` (`:168`), `struct JSONGradient` (`:242`), `class CustomSkinLoader` (`:299`, `@Observable`), `enum BuiltInSkinLoader` (`:415`) | Loads user-installed `.json` themes from `~/Library/Application Support/Bubo/Presentation/Views/Skins/`. Validates against the JSON schema. Color string formats: hex (`"#0070FA"`), named (`"accentColor"`), named-with-opacity (`"accentColor:0.5"`), keyword (`"clear"`). Missing fields fall back to baked defaults |
| `BuboSkin.swift` | 286 | `struct SkinBackgroundLayer` (`:5`) | Renders skin-specific gradient backgrounds with blend modes (gradient or radial variants). Moved here from `Presentation/Views/Common/` on 2026-05-12 — view-side rendering, but a Skin asset semantically |
| `BuiltInSkins/` | — | 9 bundled `.json` files | `Classic` (default), `System`, `Apple`, `Ocean`, `Midnight`, `Graphite`, `Sage`, `Lavender`, `Mulberry` |
| `TEMPLATE.json` | — | starter template | File users copy when authoring a custom skin |
| `buboskin.schema.json` | — | JSON Schema | Machine-readable schema. **Rejects unknown keys** so authors get errors instead of silent ignores |

## What a skin can change

Mood-only: accent colour, tint, button shape and weight, badge style, font weight, font design (face family), separator style. Skins **cannot** change:

- layout or spacing (handled by `Presentation/Views/DesignSystem.swift`),
- material backgrounds (vibrancy, blur),
- semantic colours (red/orange/green carry meaning — PRINCIPLES §7 / §10).

Typography family was historically fixed to SF Rounded; the Apple skin opens it as a per-skin choice via `fontDesign`. Defaults remain SF Rounded so existing skins are bit-identical.

The Swift schema in `SkinDefinition.swift` simply omits those fields. The JSON schema `buboskin.schema.json` rejects unknown keys. See [`../concepts/skins-system.md`](../concepts/skins-system.md).

## Loader behaviour

`CustomSkinLoader` parses the user directory at startup and on file-system observer events. Invalid JSON is logged via `OSLog` and the skin is skipped — the user-facing list shows only valid themes. The active skin id is in `ReminderSettings.selectedSkinID`.
