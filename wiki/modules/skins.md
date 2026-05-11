# Module: Skins

> **Kind:** module
> **Sources:** Bubo/Skins/
> **Last ingest:** 2026-05-11
> **Related:** [`../concepts/skins-system.md`](../concepts/skins-system.md), [`views.md`](views.md), [`../concepts/design-principles.md`](../concepts/design-principles.md)

## Files

| File | Type(s) | Role |
|---|---|---|
| `SkinDefinition.swift` | `SkinDefinition`, `SkinButtonStyle`, `SkinButtonShape`, `SkinFontWeight`, `SkinBadgeStyle`, `SkinSeparatorStyle` | The full skin schema as Swift types |
| `CustomSkinLoader.swift` | `CustomSkinJSON`, `CustomSkinLoader` | Loads user-installed `.json` themes from `~/Library/Application Support/Bubo/Skins/` and validates them against the schema |
| `BuiltInSkins/` | bundled `.json` files | Themes shipped with the app |
| `TEMPLATE.json` | reference template | Starter file users copy when authoring a custom skin |
| `buboskin.schema.json` | JSON Schema | Machine-readable schema for editors / validators |

## What a skin can change

Mood-only: accent colour, tint, button shape/weight, badge style, font weight, separator style. Skins **cannot** change:

- layout or spacing,
- material backgrounds (vibrancy, blur),
- semantic colours (red/orange/green carry meaning — see PRINCIPLES §7 and §10),
- typography family (SF Rounded is fixed — PRINCIPLES §8).

The schema enforces this by simply not exposing those fields. See [`../concepts/skins-system.md`](../concepts/skins-system.md).

## Loader behaviour

`CustomSkinLoader` parses the user directory at startup and on a file-system observer event. Invalid JSON is logged via `OSLog` and the skin is skipped — the user-facing list shows only valid themes. The active skin id is in `ReminderSettings`.
