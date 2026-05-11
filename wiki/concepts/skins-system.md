# Skins system

> **Kind:** concept
> **Sources:** Bubo/Presentation/Skins/, Bubo/Presentation/Skins/BuboSkin.swift, Bubo/Presentation/Views/DesignSystem/DesignSystem.swift, docs/design/PRINCIPLES.md
> **Last ingest:** 2026-05-12 (rev: bounded-context restructure + mega-file split)
> **Related:** [`../modules/skins.md`](../modules/skins.md), [`design-principles.md`](design-principles.md), [`../modules/views.md`](../modules/views.md)

## What

Skins are JSON-defined themes that change Bubo's mood — accent colour, button shape and weight, badge style, separator style, font weight — without altering layout, materials, or semantic colours. They are user-installable.

## The constraint

PRINCIPLES §10 (Skin boundaries): a skin must only change mood. Specifically a skin **cannot** override:

- spacing or sizing (set by `DesignSystem.swift`'s `DS` namespace),
- backgrounds (vibrancy, blur, materials),
- the meaning of red/orange/green/yellow (PRINCIPLES §7 — semantic colour is meaning),
- typography family (PRINCIPLES §8 — SF Rounded is the family; only weight varies).

The schema in `Presentation/Skins/SkinDefinition.swift` simply omits those fields, so an invalid skin can't be authored.

## Loading

`CustomSkinLoader` reads `~/Library/Application Support/Bubo/Presentation/Skins/*.json` at launch and on FS change events. Invalid files are logged to `OSLog` and skipped — the picker shows only valid skins. Built-in skins ship as JSON under `Presentation/Skins/BuiltInSkins/`.

## Active skin

`ReminderSettings` stores the active skin id. `BuboSkin.swift` exposes the resolved `SkinDefinition` to views via environment, so any view can read `dsSkin.accent`, etc.

## Adding a skin

User flow: drop a JSON file into the directory → it appears in `AppearanceTabView`'s picker. There is no in-app editor — the file is the authoring surface.
