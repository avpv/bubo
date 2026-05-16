# Module: Skins

> **Kind:** module
> **Sources:** Bubo/Presentation/Views/Skins/
> **Last ingest:** 2026-05-16 (rev: interface composition pass — Apple HIG structural rewrites, not cosmetic patches. `EventRowView` no longer carries a per-row strokeBorder (rows live inside the popover platter — one surface, not two). `EmptyState.fullCard` switched to native `ContentUnavailableView` (macOS 14 idiom: hero SF symbol + title + description + primary `.borderedProminent` action, same as Finder / Music). `DaySectionView` rebuilt as eyebrow + title + summary stack with `.regularMaterial` sticky chrome (was single-row caps-tracked with flat tinted rectangle). `OptimizerInsightsView` collapsed three fill+stroke carded tiles into one stat-group surface with internal hairline dividers (Apple Health / Fitness pattern); patterns section gets native `Label` rows with SF Symbols instead of 4pt magic-number `circle.fill` bullets; empty state switched to `ContentUnavailableView`. `MenuBarView+MainContent` stripped: command bar is now one material surface (was material fill + stroke + nested filled `⌘K` pill — three surfaces inside one control); `focusSummaryRow` deleted entirely (its three numbers duplicate info already shown in the day-section headers and footer); date header rebuilt as eyebrow + title + subtitle stack matching the section-header vocabulary one level down.)
> **Related:** [`../concepts/skins-system.md`](../concepts/skins-system.md), [`views.md`](views.md), [`../concepts/design-principles.md`](../concepts/design-principles.md)

## Files

| File | Lines | Main types (line) | Role |
|---|---:|---|---|
| `SkinDefinition.swift` | ~545 | `enum SkinButtonStyle`, `enum SkinButtonShape`, `enum SkinFontWeight`, `enum SkinFontDesign` (new), `enum SkinBadgeStyle`, `enum SkinSeparatorStyle`, `struct SkinDefinition`, `struct SkinGradient`, `enum SkinCatalog` | Full Swift schema for a skin. Button style: `.solid`, `.gradient`, `.glass`. Button shape: `.capsule`, `.roundedRect`, `.rectangle`. Font design: `.rounded` (default — SF Rounded), `.default` (SF Pro Text/Display, used by the Apple skin), `.serif`, `.monospaced` |
| `CustomSkinLoader.swift` | 526 | `struct CustomSkinJSON` (`:36`), `struct JSONColor` (`:168`), `struct JSONGradient` (`:242`), `class CustomSkinLoader` (`:299`, `@Observable`), `enum BuiltInSkinLoader` (`:415`) | Loads user-installed `.json` themes from `~/Library/Application Support/Bubo/Presentation/Views/Skins/`. Validates against the JSON schema. Color string formats: hex (`"#0070FA"`), named (`"accentColor"`), named-with-opacity (`"accentColor:0.5"`), keyword (`"clear"`). Missing fields fall back to baked defaults |
| `BuboSkin.swift` | 286 | `struct SkinBackgroundLayer` (`:5`) | Renders skin-specific gradient backgrounds with blend modes (gradient or radial variants). Moved here from `Presentation/Views/Common/` on 2026-05-12 — view-side rendering, but a Skin asset semantically |
| `BuiltInSkins/` | — | 14 bundled `.json` files | `Apple` (default), `Arctic`, `Classic`, `Graphite`, `Lavender`, `Midnight`, `Ocean`, `RoseGold`, `Sage`, `Sierra`, `System`, `WinXPBlue`, `WinXPOlive`, `WinXPSilver` |
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
