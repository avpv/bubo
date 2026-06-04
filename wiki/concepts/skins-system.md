# Skins system

> **Kind:** concept
> **Sources:** Bubo/Presentation/Views/Skins/, Bubo/Presentation/Views/Skins/BuboSkin.swift, Bubo/Presentation/Views/DesignSystem/DesignSystem.swift
> **Last ingest:** 2026-06-04 (rev: Flat skin is now the default for fresh installs; shadow/opacity defaults tightened; PR #557)
> **Related:** [`../modules/skins.md`](../modules/skins.md), [`design-principles.md`](design-principles.md), [`../modules/views.md`](../modules/views.md)

## What

Skins are JSON-defined themes that change Bubo's mood — accent colour, button shape and weight, badge style, separator style, font weight, font design (face family), and dark-mood behaviour — without altering layout, materials, or semantic colours. They are user-installable.

## The constraint

PRINCIPLES §10 (Skin boundaries): a skin must only change mood. Specifically a skin **cannot** override:

- spacing or sizing (set by `DesignSystem.swift`'s `DS` namespace),
- backgrounds (vibrancy, blur, materials),
- the meaning of red/orange/green/yellow (PRINCIPLES §7 — semantic colour is meaning).

Font design (face family) is a per-skin property since PR #553: `SkinDefinition.fontDesign` (`SkinDefinition.swift:166`) accepts `SkinFontDesign` (`.rounded`, `.default`, `.serif`, `.monospaced`). The default is `.rounded` (SF Rounded), so existing skins are bit-identical. PRINCIPLES §8's "SF Rounded is fixed" constraint no longer applies — the built-in Apple and Flat skins both use `.default` (SF Pro Text/Display).

`SkinDefinition.darkMoodMode` (`SkinDefinition.swift:166`) controls how a skin responds to the system light/dark toggle: `.auto` (follow `@Environment(\.colorScheme)` — default for all built-in skins), `.light` (force light mood), or `.dark` (force dark mood). The authored `prefersDarkTint: Bool` remains as a fallback for code paths without a SwiftUI `ColorScheme` context.

The schema in `Presentation/Views/Skins/SkinDefinition.swift` encodes these choices; `buboskin.schema.json` rejects unknown keys so invalid skins fail loudly.

## Loading

`CustomSkinLoader` reads `~/Library/Application Support/Bubo/Presentation/Views/Skins/*.json` at launch and on FS change events. Invalid files are logged to `OSLog` and skipped — the picker shows only valid skins. Built-in skins ship as JSON under `Presentation/Views/Skins/BuiltInSkins/`.

## Active skin

`ReminderSettings.selectedSkinID` (`Domain/Reminders/ReminderSettings.swift:106`) stores the active skin id; the derived `selectedSkin: SkinDefinition` (`:117`) resolves via `SkinCatalog.skin(forID:)`. `BuboSkin.swift` defines the `\.activeSkin` SwiftUI environment key (`:281`) so any view can read the current `SkinDefinition` via `@Environment(\.activeSkin)`. For fresh installs, `SkinCatalog.defaultSkin` (`SkinDefinition.swift:~651`) resolves to the Flat skin, falling back to Apple, then System.

## Adding a skin

User flow: drop a JSON file into the directory → it appears in `AppearanceTabView`'s picker. There is no in-app editor — the file is the authoring surface.
