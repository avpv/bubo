# Module: Skins

> **Kind:** module
> **Sources:** Bubo/Skins/
> **Last ingest:** 2026-05-11
> **Related:** [`../concepts/skins-system.md`](../concepts/skins-system.md), [`views.md`](views.md), [`../concepts/design-principles.md`](../concepts/design-principles.md)

## Files

| File | Lines | Main types (line) | Role |
|---|---:|---|---|
| `SkinDefinition.swift` | 523 | `enum SkinButtonStyle` (`:8`), `enum SkinButtonShape` (`:19`), `enum SkinFontWeight`, `enum SkinBadgeStyle`, `enum SkinSeparatorStyle`, plus the main `struct SkinDefinition` | Full Swift schema for a skin. Button style: `.solid`, `.gradient`, `.glass`. Button shape: `.capsule`, `.roundedRect`, `.rectangle`. Font weights exclude `ultraLight` / `thin` per HIG legibility rules — comment cites Birman: "a skin should pick ONE body weight, not three" |
| `CustomSkinLoader.swift` | 526 | `struct CustomSkinJSON`, `enum CustomSkinLoader` | Loads user-installed `.json` themes from `~/Library/Application Support/Bubo/Skins/`. Validates against the JSON schema. Color string formats: hex (`"#0070FA"`), named (`"accentColor"`), named-with-opacity (`"accentColor:0.5"`), keyword (`"clear"`). Minimal required field set — author thinks in terms of mood, not shadow radii. Missing fields fall back to baked defaults |
| `BuiltInSkins/` | — | bundled `.json` files | Themes shipped with the app (e.g. `Classic.json`) |
| `TEMPLATE.json` | — | starter template | File users copy when authoring a custom skin |
| `buboskin.schema.json` | — | JSON Schema | Machine-readable schema. **Rejects unknown keys** so authors get errors instead of silent ignores |

## What a skin can change

Mood-only: accent colour, tint, button shape and weight, badge style, font weight, separator style. Skins **cannot** change:

- layout or spacing (handled by `Views/DesignSystem.swift`),
- material backgrounds (vibrancy, blur),
- semantic colours (red/orange/green carry meaning — PRINCIPLES §7 / §10),
- typography family (SF Rounded is fixed — PRINCIPLES §8).

The Swift schema in `SkinDefinition.swift` simply omits those fields. The JSON schema `buboskin.schema.json` rejects unknown keys. See [`../concepts/skins-system.md`](../concepts/skins-system.md).

## Loader behaviour

`CustomSkinLoader` parses the user directory at startup and on file-system observer events. Invalid JSON is logged via `OSLog` and the skin is skipped — the user-facing list shows only valid themes. The active skin id is in `ReminderSettings.selectedSkinID`.
