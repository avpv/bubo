# Skins system

> **Kind:** concept
> **Sources:** Bubo/Presentation/Views/Skins/, Bubo/Presentation/Views/Skins/BuboSkin.swift, Bubo/Presentation/Views/DesignSystem/DesignSystem.swift
> **Last ingest:** 2026-05-12
> **Related:** [`../modules/skins.md`](../modules/skins.md), [`design-principles.md`](design-principles.md), [`../modules/views.md`](../modules/views.md)

## What

Skins are JSON-defined themes that change Bubo's mood — accent colour, button shape and weight, badge style, separator style, font weight — without altering layout, materials, or semantic colours. They are user-installable.

## The constraint

PRINCIPLES §10 (Skin boundaries): a skin must only change mood. Specifically a skin **cannot** override:

- spacing or sizing (set by `DesignSystem.swift`'s `DS` namespace),
- backgrounds (vibrancy, blur, materials),
- the meaning of red/orange/green/yellow (PRINCIPLES §7 — semantic colour is meaning),
- typography family (PRINCIPLES §8 — SF Rounded is the family; only weight varies).

The schema in `Presentation/Views/Skins/SkinDefinition.swift` simply omits those fields, so an invalid skin can't be authored.

## Loading

`CustomSkinLoader` reads `~/Library/Application Support/Bubo/Presentation/Views/Skins/*.json` at launch and on FS change events. Invalid files are logged to `OSLog` and skipped — the picker shows only valid skins. Built-in skins ship as JSON under `Presentation/Views/Skins/BuiltInSkins/`.

## Active skin

`ReminderSettings.selectedSkinID` (`Domain/Reminders/ReminderSettings.swift:106`) stores the active skin id; the derived `selectedSkin: SkinDefinition` (`:118`) resolves via `SkinCatalog.skin(forID:)`. `BuboSkin.swift` defines the `\.activeSkin` SwiftUI environment key (`:276`) so any view can read the current `SkinDefinition` via `@Environment(\.activeSkin)`.

## Adding a skin

User flow: drop a JSON file into the directory → it appears in `AppearanceTabView`'s picker. There is no in-app editor — the file is the authoring surface.
