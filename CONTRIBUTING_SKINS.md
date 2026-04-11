# Contributing a Bubo Skin

Bubo supports community-contributed skins — visual themes that change the app's
accent colors, background gradient, and surface tinting. Think of it like
[Winamp skins](https://skins.webamp.org/) but for a calendar app.

All skins — both built-in and custom — use the same `.json` skin format.
One unified approach for everything.

> **Design philosophy.** A skin describes **mood**, not layout. Shadow depth,
> materials, shapes, symbol rendering, animation physics and semantic colors
> are fixed across the app so that no skin can break the layout rhythm or
> reinterpret the meaning of red / green / orange. If you find yourself
> wishing for `shadowRadius` or `platterMaterial`, the fix is almost always
> to change the accent and gradient instead.

## Quick Start

1. **Copy the template**

   ```
   cp Bubo/Skins/TEMPLATE.json MyNewSkin.json
   ```

2. **Edit the JSON values.** Only seven fields are required; everything else
   is optional and defaults to a sensible value.

   | Property | What it does |
   |----------|-------------|
   | `id` | Unique identifier (lowercase_snake_case). **Never change after merge.** |
   | `displayName` | Shown in Settings → Skin picker |
   | `author` | Your name or `@github_handle` |
   | `accentColor` | Buttons, highlights, tint, accent bars |
   | `prefersDarkTint` | `true` for dark/moody skins (also deepens shadows) |
   | `backgroundGradient` | Ambient glow behind the UI |
   | `previewColors` | 1–2 colors for the thumbnail in the picker |

3. **For built-in skins** — place the `.json` file in
   `Bubo/Skins/BuiltInSkins/` and add the skin's `id` to the `order` array
   in `BuiltInSkinLoader` (inside `CustomSkinLoader.swift`).

   **For personal skins** — import via Settings → Skin → Import skin .json file
   (no code changes needed).

4. **Open a PR** with your new `.json` skin file. That's it!

## Minimal example

```json
{
  "id": "my_skin_name",
  "displayName": "My Skin Name",
  "author": "@your_github",
  "accentColor": "#00E600",
  "prefersDarkTint": true,
  "backgroundGradient": {
    "colors": ["#002E0080", "#001A0D4C", "clear"],
    "style": "linear",
    "startPoint": "topLeading",
    "endPoint": "bottomTrailing"
  },
  "previewColors": ["#00B200", "#1A3319"]
}
```

That's a complete, valid skin. All other fields are optional.

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
system accent — see `System.json` for an example.

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
| `accentColor` | color | Primary accent color (must meet 3:1 contrast vs white) |
| `prefersDarkTint` | bool | `true` for dark/moody skins |
| `backgroundGradient` | gradient | Ambient background glow |
| `previewColors` | color[] | 1–2 colors for picker thumbnail |

### Optional — Mood

| Property | Description | Default |
|----------|-------------|---------|
| `secondaryAccent` | Used for gradient end-point and derived highlights | `accentColor` at 85% |

### Optional — Surface Tints

| Property | Description | Default |
|----------|-------------|---------|
| `barTint` | Color wash on header/footer bars | None |
| `barTintOpacity` | Opacity of `barTint` | `0.08` |
| `platterTint` | Color wash on card/platter surfaces | None |
| `platterTintOpacity` | Opacity of `platterTint` | `0.05` |

### Optional — Buttons

| Property | Values | Default |
|----------|--------|---------|
| `buttonStyle` | `"solid"`, `"gradient"`, `"glass"` | `"gradient"` |
| `buttonShape` | `"capsule"`, `"roundedRect"`, `"rectangle"` | `"capsule"` |
| `buttonColor` | color — foreground color of primary buttons | auto-contrast |
| `buttonAccentColor` | color — accent override for primary button background | `accentColor` |
| `buttonSecondaryAccent` | color — gradient end-point override | derived |
| `buttonTint` | color — overlay on glass-style primary buttons | `accentColor` |

### Optional — Typography

| Property | Values | Default |
|----------|--------|---------|
| `fontWeight` | `"regular"`, `"medium"`, `"semibold"`, `"bold"` | `"regular"` |

`fontWeight` controls body text and buttons. Headline weight and SF Symbol
weight are derived from it automatically (HIG: "match symbol weight to
adjacent text weight").

### Optional — Appearance

| Property | Values | Default |
|----------|--------|---------|
| `badgeStyle` | `"tinted"`, `"filled"`, `"outlined"` | `"tinted"` |
| `separatorStyle` | `"subtle"`, `"system"`, `"accent"`, `"none"` | `"subtle"` |

## What's **not** configurable

The following are fixed globally and cannot be overridden per skin:

- **Materials** — bars use `.thick`, platters use `.regular`, buttons use
  `.regular`. Uniform translucency is part of the app's identity.
- **Shadow depth** — `shadowRadius`, `shadowY`, `hoverShadowRadius`,
  `hoverShadowY`, `platterBorderOpacity`, `hoverFillOpacity` are all baked
  into `SkinDefinition`. Shadow *opacity* is derived from `prefersDarkTint`.
- **Font design** — always SF Rounded. HIG forbids custom typefaces in
  utility-class windows.
- **Symbol rendering** — always hierarchical. Recommended by HIG for utility
  apps.
- **Animation physics** — one spring profile for the whole product. A product
  has one motion signature, not a palette.
- **Semantic colors** — `destructiveColor` = system red, `successColor` =
  system green, `warningColor` = system orange. These carry meaning; the user
  must be able to recognise them regardless of which skin is active.
- **Text colors** — system label colors so Dark Mode and Accessibility
  settings always work.
- **Toolbar tint** — derived as `accentColor` at 70%.
- **Surface tint** — derived from `accentColor` and `prefersDarkTint`.

If your skin genuinely needs something different here, open an issue — adding
a knob should be a deliberate product decision, not a JSON field.

## Design Tips

- **Accent color**: Pick one strong, saturated color. This drives the entire
  visual identity. Avoid grey/desaturated accents — interactive elements must
  be visually distinct from non-interactive text (aim for ≥ 3:1 contrast
  against white).
- **Background gradient**: Use 2–3 stops fading to clear. Opacity should be
  0.10–0.25 so the gradient doesn't overpower content.
- **Preview colors**: The first color should be your accent; the second a
  complementary dark tone.
- **`buttonStyle: "gradient"`**: Renders a gradient from `accentColor` →
  `secondaryAccent`. Always set `secondaryAccent` when using gradient buttons,
  otherwise it falls back to a dimmed version of `accentColor` (subtle shift).
- **Test both light & dark mode** — skins use adaptive blend modes that work
  in both, but some color combos look better in one mode.

## Apple Human Interface Guidelines

- **3:1 minimum contrast** — interactive elements must have at least 3:1
  contrast ratio against their background. Accents too light or too dark to
  meet this threshold will look broken. The skin loader emits a warning.
- **Respect system appearance** — skins must work in both Light and Dark
  Mode. Avoid hard-coded colors that only look right in one mode.
- **Don't fight the system blur** — bar and platter materials provide
  vibrancy. Keep tint opacities subtle (≤ 0.15) so the material can still do
  its job.
- **Don't rely on color alone** — if your skin conveys meaning through color
  (tinted badges), ensure shape or label also carries the information for
  users with color vision deficiency.

For the full guidelines, see
[Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/).

## JSON Schema Validation

A JSON Schema is available at `Bubo/Skins/buboskin.schema.json`. It validates
all keys, types, enums, and required fields. VS Code users get automatic
validation and autocomplete for skin `.json` files (see `.vscode/settings.json`).

The schema is lenient on unknown keys — older skin files with removed fields
like `shadowRadius` or `sfSymbolWeight` will still pass validation and load
cleanly. Those values are silently dropped in favour of the baked defaults.

To validate a skin manually:

```sh
pip install jsonschema
python3 -c "import json,jsonschema; jsonschema.validate(json.load(open('MySkin.json')), json.load(open('Bubo/Skins/buboskin.schema.json')))"
```

## File Structure

```
Bubo/Skins/
├── SkinDefinition.swift       # Core struct + catalog registry
├── CustomSkinLoader.swift     # JSON loading (built-in + custom)
├── buboskin.schema.json       # JSON Schema for validation
├── TEMPLATE.json              # Copy this to start a new skin
└── BuiltInSkins/              # Bundled default skins (always present)
    ├── System.json
    ├── Classic.json
    ├── Graphite.json
    ├── Ocean.json
    ├── Lavender.json
    ├── RoseGold.json
    ├── Midnight.json
    ├── Sierra.json
    ├── Arctic.json
    ├── Sage.json
    ├── WinXPBlue.json
    ├── WinXPOlive.json
    └── WinXPSilver.json
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
Select a skin, then use the "Choose image…" button to pick a photo.
Opacity and blur can be adjusted per skin.

Custom skins are stored in `~/Library/Application Support/Bubo/Skins/`.
You can also drop skin `.json` files there directly and restart Bubo.

Right-click a community skin in the picker to remove it.

## Example

See any built-in skin in `Bubo/Skins/BuiltInSkins/` for a complete working
example, or `TEMPLATE.json` for the format.
