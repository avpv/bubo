# Skins system

> **Kind:** concept
> **Sources:** Bubo/Presentation/Views/Skins/, Bubo/Presentation/Views/Skins/BuboSkin.swift, Bubo/Presentation/Views/DesignSystem/DesignSystem.swift
> **Last ingest:** 2026-07-16 (rev: wiki-ingest for PR #593 — `legibilityScrim` and `readableAccent`'s contrast floor both gained hue/saturation awareness (DESIGN_REVIEW R5); see «Backdrop legibility» below. Prior rev: backdrop legibility contract — `SkinDefinition.adaptedToBackdrop(_:)` nudges the canvas-facing accent toward the readable pole over the active wallpaper; `==` now compares `id` **and** `accentColor` so adapted same-id copies propagate through the environment. Prior rev: `fontDesign` and `darkMoodMode` added to `SkinDefinition`; typography family is now a per-skin property; constraint section updated; PR #553)
> **Related:** [`../modules/skins.md`](../modules/skins.md), [`design-principles.md`](design-principles.md), [`../modules/views.md`](../modules/views.md)

## What

Skins are JSON-defined themes that change Bubo's mood — accent colour, button shape and weight, badge style, separator style, font weight, font design (face family), and dark-mood behaviour — without altering layout, materials, or semantic colours. They are user-installable.

## The constraint

PRINCIPLES §10 (Skin boundaries): a skin must only change mood. Specifically a skin **cannot** override:

- spacing or sizing (set by `DesignSystem.swift`'s `DS` namespace),
- backgrounds (vibrancy, blur, materials),
- the meaning of red/orange/green/yellow (PRINCIPLES §7 — semantic colour is meaning).

Font design (face family) is a per-skin property since PR #553: `SkinDefinition.fontDesign` (`SkinDefinition.swift:166`) accepts `SkinFontDesign` (`.rounded`, `.default`, `.serif`, `.monospaced`). The default is `.rounded` (SF Rounded), so existing skins are bit-identical. PRINCIPLES §8's "SF Rounded is fixed" constraint no longer applies — the built-in Apple skin uses `.default` (SF Pro Text/Display).

`SkinDefinition.darkMoodMode` (`SkinDefinition.swift:166`) controls how a skin responds to the system light/dark toggle: `.auto` (follow `@Environment(\.colorScheme)` — default for all built-in skins), `.light` (force light mood), or `.dark` (force dark mood). The authored `prefersDarkTint: Bool` remains as a fallback for code paths without a SwiftUI `ColorScheme` context.

The schema in `Presentation/Views/Skins/SkinDefinition.swift` encodes these choices; `buboskin.schema.json` rejects unknown keys so invalid skins fail loudly.

## Loading

`CustomSkinLoader` reads `~/Library/Application Support/Bubo/Presentation/Views/Skins/*.json` at launch and on FS change events. Invalid files are logged to `OSLog` and skipped — the picker shows only valid skins. Built-in skins ship as JSON under `Presentation/Views/Skins/BuiltInSkins/`.

## Active skin

`ReminderSettings.selectedSkinID` (`Domain/Reminders/ReminderSettings.swift:106`) stores the active skin id; the derived `selectedSkin: SkinDefinition` (`:117`) resolves via `SkinCatalog.skin(forID:)`. `BuboSkin.swift` defines the `\.activeSkin` SwiftUI environment key (`:281`) so any view can read the current `SkinDefinition` via `@Environment(\.activeSkin)`.

## Backdrop legibility

Skins and wallpapers combine on one canvas, and before 2026-07-15 nothing guaranteed the combination stayed readable (white `labelColor` on a light wallpaper under system Dark Mode; a blue accent swallowed by a blue wallpaper). `Presentation/Views/Components/Background/BackdropLegibility.swift` is the contract:

- `WallpaperDefinition.contentColorScheme(for:)` derives the forced foreground polarity from the wallpaper's canvas luminance; `MenuBarView` and the pinned-timer panel apply it via `View.backdropColorScheme(_:)` so labels, materials and separators flip together. `nil` (no wallpaper, or `auto` + Classic) follows the system appearance.
- `legibilityScrim(for:)` returns a faint pole-ward wash for mid-luminance canvases, **and** (since PR #593, DESIGN_REVIEW R5) for saturated canvases regardless of luminance band — a `satTerm` (up to ~0.16 at full saturation, gated on saturation > 0.45) floors the opacity so vivid-blue canvases like Cobalt/Monterey get a scrim even when their luminance sits outside the old mid-band.
- `SkinDefinition.adaptedToBackdrop(_:)` returns a same-id copy whose accent is blended toward the readable pole until it clears an adaptive WCAG contrast floor. The floor is now hue-aware (PR #593, DESIGN_REVIEW R5): `min(3.0, 0.8 × pole contrast)` normally, but when the accent and canvas hues collide (`DS.hueSaturation`/`hueDistance` — both saturation > 0.25 and hue distance < 0.09, i.e. ≈32°) chroma can't separate them, so the floor rises to `min(4.5, 0.95 × pole contrast)` — the blue-accent-on-blue-wallpaper fix. Button colors are frozen to the authored resolution because button text contrasts against the button fill, not the canvas. `SkinDefinition.==` compares `id` + `accentColor` so the adapted copy propagates through `\.activeSkin`.

## Adding a skin

User flow: drop a JSON file into the directory → it appears in `AppearanceTabView`'s picker. There is no in-app editor — the file is the authoring surface.
