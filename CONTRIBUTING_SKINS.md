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

2. **Edit the JSON values** — each field is documented below.
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
  "accentColor": "#00E600",
  "surfaceTint": "#002600",
  "surfaceTintOpacity": 0.35,
  "backgroundGradient": {
    "colors": ["#002E0080", "#001A0D4C", "clear"],
    "style": "linear",
    "startPoint": "topLeading",
    "endPoint": "bottomTrailing"
  },
  "previewColors": ["#00B200", "#1A3319"],
  "prefersDarkTint": true,
  "secondaryAccent": "#00A626",
  "buttonStyle": "gradient"
}
```

## Colors

Every color field accepts any of these formats:

| Format | Example | Notes |
|--------|---------|-------|
| Hex RGB | `"#0070FA"` | 6-digit, fully opaque |
| Hex RGBA | `"#0070FA80"` | 8-digit, last byte = alpha (80 ≈ 50%) |
| Named color | `"accentColor"` | Follows the user's system accent |
| Named + opacity | `"accentColor:0.5"` | Named color at 50% opacity |
| Keyword | `"clear"`, `"white"`, `"black"`, `"gray"` | Common colors |

**Hex is the recommended format** — compact and universally understood.
Use any color picker to get the hex value.

Named colors (`"accentColor"`) are useful for skins that adapt to the user's
system accent — see `System.buboskin` for an example.

## Gradients

**Linear** — flows between two corners/edges:
```json
{ "style": "linear", "colors": ["#0059BF38", "clear"], "startPoint": "topLeading", "endPoint": "bottomTrailing" }
```

**Radial** — radiates from a center point:
```json
{ "style": "radial", "colors": ["#0059BF38", "clear"], "center": "top", "startRadius": 0, "endRadius": 500 }
```

**Clear** — no gradient (transparent):
```json
{ "style": "clear" }
```

Gradient color stops support hex with alpha for transparency:
`"#0059BF38"` (the `38` = ~22% opacity). Use `"clear"` for a fully transparent stop.

Valid point values: `top`, `bottom`, `leading`, `trailing`, `topLeading`,
`topTrailing`, `bottomLeading`, `bottomTrailing`, `center`.

## All Properties

### Required

| Property | Type | Description |
|----------|------|-------------|
| `id` | string | Unique ID (lowercase_snake_case). Permanent. |
| `displayName` | string | Display name in the skin picker |
| `author` | string | Author name or `@github_handle` |
| `accentColor` | color | Primary accent color |
| `surfaceTint` | color | Mood overlay on surfaces |
| `surfaceTintOpacity` | 0–1 | Surface tint intensity |
| `backgroundGradient` | gradient | Ambient background glow |
| `previewColors` | color[] | 1–2 colors for picker thumbnail |
| `prefersDarkTint` | bool | `true` for dark/moody skins |

### Optional — Buttons

| Property | Values | Default |
|----------|--------|---------|
| `buttonStyle` | `"solid"`, `"gradient"`, `"glass"` | `"gradient"` |
| `buttonShape` | `"capsule"`, `"roundedRect"`, `"rectangle"` | `"capsule"` |
| `buttonColor` | color | Auto-derived from accent luminance |
| `buttonMaterial` | material | `"regular"` |
| `buttonTint` | color | Falls back to accentColor |
| `buttonTintOpacity` | 0–1 | `0.3` |
| `secondaryAccent` | color | Falls back to darkened accentColor |

### Optional — Bars & Surfaces

| Property | Values | Default |
|----------|--------|---------|
| `barMaterial` | `"ultraThin"`, `"thin"`, `"regular"`, `"thick"`, `"ultraThick"`, `"bar"` | `"thick"` |
| `barTint` | color | None |
| `barTintOpacity` | 0–1 | `0` |
| `platterMaterial` | material (same values) | `"regular"` |
| `platterTint` | color | None |
| `platterTintOpacity` | 0–1 | `0` |
| `toolbarTint` | color | Falls back to accentColor at 70% |

### Optional — Semantic Colors

| Property | Type | Default |
|----------|------|---------|
| `destructiveColor` | color | System red (`#FF3B30`) |
| `successColor` | color | System green (`#34C759`) |
| `warningColor` | color | System orange (`#FF9500`) |

These colors are used for delete/remove actions, success states, and warnings
respectively. Override them to match your skin's palette — e.g. a warm skin
might use a coral-red for destructive and amber for warning.

### Optional — Typography & Symbols

| Property | Values | Default |
|----------|--------|---------|
| `fontDesign` | `"default"`, `"rounded"` | `"rounded"` |
| `fontWeight` | `"regular"`, `"medium"`, `"semibold"`, `"bold"` | `"semibold"` |
| `headlineFontWeight` | same as fontWeight | `"semibold"` |
| `sfSymbolRendering` | `"monochrome"`, `"hierarchical"`, `"palette"`, `"multicolor"` | `"hierarchical"` |
| `sfSymbolWeight` | `"ultraLight"` – `"black"` | `"medium"` |
| `badgeStyle` | `"tinted"`, `"filled"`, `"outlined"` | `"tinted"` |
| `separatorStyle` | `"system"`, `"subtle"`, `"accent"`, `"none"` | `"system"` |
| `separatorOpacity` | 0–1 | `0.5` |

## Design Tips

- **Accent color**: Pick one strong, saturated color. This drives the entire
  visual identity. Avoid grey/desaturated accents — interactive elements must
  be visually distinct from non-interactive text (aim for ≥ 3:1 contrast).
- **Surface tint**: Use a very dark, desaturated version of your accent. High
  opacity here overwhelms the UI — keep it subtle (0.2–0.35).
- **Background gradient**: Use 2–3 stops fading to clear. Opacity should be
  0.10–0.25 so the gradient doesn't overpower content.
- **Preview colors**: The first color should be your accent; the second a
  complementary dark tone.
- **`buttonStyle: "gradient"`**: Renders a gradient from `accentColor` →
  `secondaryAccent`. Always set `secondaryAccent` when using gradient buttons,
  otherwise it falls back to a darkened version of `accentColor` (subtle shift).
- **`secondaryAccent` fallback**: If omitted, defaults to `accentColor` at 85%
  opacity. For distinct visual hierarchy, always provide an explicit value.
- **`toolbarTint`**: Intentionally different from `accentColor` to create
  hierarchy — primary actions (Add) use the accent, toolbar buttons recede.
  Choose a complementary, lower-saturation color.
- **Test both light & dark mode** — skins use adaptive blend modes that work in
  both, but some color combos look better in one mode.

## Value Constraints

The JSON schema enforces these ranges to prevent broken skins:

| Property | Min | Max | Notes |
|----------|-----|-----|-------|
| `cornerRadius` | 2 | 24 | Avoids invisible or cartoonish rounding |
| `shadowOpacity` | 0 | 0.25 | Prevents overpowering drop shadows |
| `shadowRadius` | 0 | 20 | Keeps shadows plausible |
| `separatorOpacity` | 0.05 | 0.5 | Runtime floor at 0.15 when style ≠ `"none"` |

## JSON Schema Validation

A JSON Schema is available at `Bubo/Skins/buboskin.schema.json`. It validates
all keys, types, enums, and required fields. VS Code users get automatic
validation and autocomplete for `.buboskin` files (see `.vscode/settings.json`).

To validate a skin manually:

```sh
pip install jsonschema
python3 -c "import json,jsonschema; jsonschema.validate(json.load(open('MySkin.buboskin')), json.load(open('Bubo/Skins/buboskin.schema.json')))"
```

## File Structure

```
Bubo/Skins/
├── SkinDefinition.swift       # Core struct + catalog registry
├── CustomSkinLoader.swift     # JSON loading (built-in + custom)
├── buboskin.schema.json       # JSON Schema for validation
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
- **Use hex for custom colors** (`"#0070FA"`) — compact, universal, easy to
  pick from any color tool. Reserve named colors (`"accentColor"`) for skins
  that intentionally follow the system accent.

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
