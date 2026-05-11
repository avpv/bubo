# Module: Skins

> **Kind:** module
> **Sources:** Bubo/Presentation/Skins/
> **Last ingest:** 2026-05-12 (rev: Common/ViewModels/Optimizer subfolder rename + BuboTests — BuboSkin.swift relocated here from Views/Common/)
> **Related:** [`../concepts/skins-system.md`](../concepts/skins-system.md), [`views.md`](views.md), [`../concepts/design-principles.md`](../concepts/design-principles.md)

## Files

| File | Lines | Main types (line) | Role |
|---|---:|---|---|
| `SkinDefinition.swift` | 523 | `enum SkinButtonStyle` (`:6`), `enum SkinButtonShape` (`:18`), `enum SkinFontWeight` (`:32`), `enum SkinBadgeStyle` (`:51`), `enum SkinSeparatorStyle` (`:63`), `struct SkinDefinition` (`:89`), `struct SkinGradient` (`:475`), `enum SkinCatalog` (`:501`) | Full Swift schema for a skin. Button style: `.solid`, `.gradient`, `.glass`. Button shape: `.capsule`, `.roundedRect`, `.rectangle`. Font weights exclude `ultraLight` / `thin` per HIG legibility rules |
| `CustomSkinLoader.swift` | 526 | `struct CustomSkinJSON` (`:36`), `struct JSONColor` (`:168`), `struct JSONGradient` (`:242`), `class CustomSkinLoader` (`:299`, `@Observable`), `enum BuiltInSkinLoader` (`:415`) | Loads user-installed `.json` themes from `~/Library/Application Support/Bubo/Presentation/Skins/`. Validates against the JSON schema. Color string formats: hex (`"#0070FA"`), named (`"accentColor"`), named-with-opacity (`"accentColor:0.5"`), keyword (`"clear"`). Missing fields fall back to baked defaults |
| `BuboSkin.swift` | 286 | `struct SkinBackgroundLayer` (`:5`) | Renders skin-specific gradient backgrounds with blend modes (gradient or radial variants). Moved here from `Presentation/Views/Common/` on 2026-05-12 — view-side rendering, but a Skin asset semantically |
| `BuiltInSkins/` | — | 13 bundled `.json` files | `Arctic`, `Classic`, `Graphite`, `Lavender`, `Midnight`, `Ocean`, `RoseGold`, `Sage`, `Sierra`, `System`, `WinXPBlue`, `WinXPOlive`, `WinXPSilver` |
| `TEMPLATE.json` | — | starter template | File users copy when authoring a custom skin |
| `buboskin.schema.json` | — | JSON Schema | Machine-readable schema. **Rejects unknown keys** so authors get errors instead of silent ignores |

## What a skin can change

Mood-only: accent colour, tint, button shape and weight, badge style, font weight, separator style. Skins **cannot** change:

- layout or spacing (handled by `Presentation/Views/DesignSystem.swift`),
- material backgrounds (vibrancy, blur),
- semantic colours (red/orange/green carry meaning — PRINCIPLES §7 / §10),
- typography family (SF Rounded is fixed — PRINCIPLES §8).

The Swift schema in `SkinDefinition.swift` simply omits those fields. The JSON schema `buboskin.schema.json` rejects unknown keys. See [`../concepts/skins-system.md`](../concepts/skins-system.md).

## Loader behaviour

`CustomSkinLoader` parses the user directory at startup and on file-system observer events. Invalid JSON is logged via `OSLog` and the skin is skipped — the user-facing list shows only valid themes. The active skin id is in `ReminderSettings.selectedSkinID`.
