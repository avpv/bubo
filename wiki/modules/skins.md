# Module: Skins

> **Kind:** module
> **Sources:** Bubo/Presentation/Views/Skins/
> **Last ingest:** 2026-05-16 (rev: background-stack paired with skin character. New `WallpaperCatalog.auto` sentinel — when active, the wallpaper layer renders the skin's authored `backgroundGradient` at full saturation, owning the whole canvas instead of whispering at 20% alpha. `AppBackgroundLayer` suppresses its own `SkinBackgroundLayer` in this mode to avoid double-paint, and damps the surface-tint overlay so the gravity-of-light direction stays legible. `WallpaperPreviewCard` renders the auto swatch as a live preview of the active skin's gradient with a small `wand.and.stars` glyph. Default `selectedWallpaperID` flipped from `none` to `auto` for fresh installs (existing users keep whatever id they persisted). All 14 skin authored characters from the previous pass now ship as both the subtle decorative layer AND the rich backdrop — same metaphor, two intensities, one knob to switch.)
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
