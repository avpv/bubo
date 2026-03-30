# Contributing a Bubo Skin

Bubo supports community-contributed skins — visual themes that change the app's
accent colors, background gradient, and surface tinting. Think of it like
[Winamp skins](https://skins.webamp.org/) but for a calendar app.

All skins — both built-in and custom — use the same `.buboskin` JSON format.
One unified approach for everything.

## Quick Start

1. **Copy the template**

   ```
   cp Bubo/Skins/TEMPLATE.buboskin MyNewSkin.buboskin
   ```

2. **Edit the JSON values** — each field is documented in the template.
   The key properties:

   | Property | What it does |
   |----------|-------------|
   | `id` | Unique identifier (lowercase_snake_case). **Never change after merge.** |
   | `displayName` | Shown in Settings → Skin picker |
   | `author` | Your name or `@github_handle` |
   | `accentColor` | Buttons, highlights, tint, accent bars |
   | `surfaceTint` | Subtle mood overlay on surfaces (keep it dark/muted) |
   | `surfaceTintOpacity` | 0 = invisible, 0.2–0.4 = typical |
   | `backgroundGradient` | Ambient glow behind the UI |
   | `previewColors` | 1–2 colors for the thumbnail in the picker |
   | `prefersDarkTint` | `true` for dark/moody skins |

3. **For built-in skins** — place the `.buboskin` file in
   `Bubo/Skins/BuiltInSkins/` and add the skin's `id` to the `order` array
   in `BuiltInSkinLoader` (inside `CustomSkinLoader.swift`).

   **For personal skins** — import via Settings → Skin → Import .buboskin file
   (no code changes needed).

4. **Open a PR** with your new `.buboskin` file. That's it!

## JSON Format

```json
{
  "id": "my_skin_name",
  "displayName": "My Skin Name",
  "author": "@your_github",
  "accentColor": { "red": 0.0, "green": 0.9, "blue": 0.0 },
  "surfaceTint": { "red": 0.0, "green": 0.15, "blue": 0.0 },
  "surfaceTintOpacity": 0.35,
  "backgroundGradient": {
    "colors": [
      { "red": 0.0, "green": 0.18, "blue": 0.0, "opacity": 0.5 },
      { "red": 0.0, "green": 0.08, "blue": 0.0, "opacity": 0.3 },
      { "red": 0.0, "green": 0.0, "blue": 0.0, "opacity": 0.0 }
    ],
    "style": "linear",
    "startPoint": "topLeading",
    "endPoint": "bottomTrailing"
  },
  "previewColors": [
    { "red": 0.0, "green": 0.7, "blue": 0.0 },
    { "red": 0.1, "green": 0.2, "blue": 0.1 }
  ],
  "prefersDarkTint": true,
  "secondaryAccent": { "red": 0.0, "green": 0.65, "blue": 0.15 },
  "buttonStyle": "gradient"
}
```

### Colors

Colors use `red`, `green`, `blue` (0.0–1.0) with an optional `opacity`.

You can also use named system colors with the `name` field:

```json
{ "name": "accentColor" }
{ "name": "accentColor", "opacity": 0.5 }
{ "name": "clear" }
{ "name": "gray" }
{ "name": "white" }
```

When `name` is set, `red`/`green`/`blue` are ignored.

### Gradients

Two gradient styles are available:

```json
// Linear — flows between two corners/edges
{ "style": "linear", "startPoint": "topLeading", "endPoint": "bottomTrailing" }

// Radial — radiates from a center point
{ "style": "radial", "center": "top", "startRadius": 0, "endRadius": 500 }

// Clear — no gradient (transparent)
{ "style": "clear" }
```

Valid point values: `top`, `bottom`, `leading`, `trailing`, `topLeading`,
`topTrailing`, `bottomLeading`, `bottomTrailing`, `center`.

### Button & Typography Options

| Property | Values | Default |
|----------|--------|---------|
| `buttonStyle` | `"solid"`, `"gradient"`, `"glass"` | `"gradient"` |
| `buttonShape` | `"capsule"`, `"roundedRect"`, `"rectangle"` | `"capsule"` |
| `barMaterial` | `"ultraThin"`, `"thin"`, `"regular"`, `"thick"`, `"ultraThick"`, `"bar"` | `"thick"` |
| `fontDesign` | `"default"`, `"rounded"`, `"serif"`, `"monospaced"` | `"rounded"` |
| `fontWeight` | `"regular"`, `"medium"`, `"semibold"`, `"bold"` | `"semibold"` |
| `sfSymbolRendering` | `"monochrome"`, `"hierarchical"`, `"palette"`, `"multicolor"` | `"hierarchical"` |
| `badgeStyle` | `"tinted"`, `"filled"`, `"outlined"` | `"tinted"` |
| `separatorStyle` | `"system"`, `"subtle"`, `"accent"`, `"none"` | `"system"` |

## Design Tips

- **Accent color**: Pick one strong, saturated color. This drives the entire
  visual identity.
- **Surface tint**: Use a very dark, desaturated version of your accent. High
  opacity here overwhelms the UI — keep it subtle (0.2–0.35).
- **Background gradient**: Use 2–3 stops fading to clear. Opacity should be
  0.10–0.25 so the gradient doesn't overpower content.
- **Preview colors**: The first color should be your accent; the second a
  complementary dark tone.
- **Test both light & dark mode** — skins use adaptive blend modes that work in
  both, but some color combos look better in one mode.

## File Structure

```
Bubo/Skins/
├── SkinDefinition.swift       # Core struct + catalog registry
├── CustomSkinLoader.swift     # JSON loading (built-in + custom)
├── TEMPLATE.buboskin          # Copy this to start a new skin
└── BuiltInSkins/              # Bundled default skins (always present)
    ├── System.buboskin
    ├── Classic.buboskin
    ├── Graphite.buboskin
    ├── Ocean.buboskin
    ├── Lavender.buboskin
    ├── RoseGold.buboskin
    ├── Midnight.buboskin
    ├── Sierra.buboskin
    ├── Arctic.buboskin
    ├── Sage.buboskin
    ├── WinXPBlue.buboskin
    ├── WinXPOlive.buboskin
    └── WinXPSilver.buboskin
```

## Rules

- **Skin IDs are permanent** — once merged, never rename the `id` field.
  Users' settings reference this string.
- **One file per skin** — keeps diffs clean and avoids merge conflicts.
- **Use `{ "red": ..., "green": ..., "blue": ... }` for custom colors** —
  avoid named colors unless you specifically need system-dynamic behavior.

## Background Images

Users can set a custom background image for any skin directly in Settings.
Select a skin, then use the "Choose image..." button to pick a photo.
Opacity and blur can be adjusted per skin.

Custom skins are stored in `~/Library/Application Support/Bubo/Skins/`.
You can also drop `.buboskin` files there directly and restart Bubo.

Right-click a community skin in the picker to remove it.

## Example

See any built-in skin in `Bubo/Skins/BuiltInSkins/` for a complete working
example, or `TEMPLATE.buboskin` for the format.
