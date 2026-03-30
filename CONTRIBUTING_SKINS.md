# Contributing a Bubo Skin

Bubo supports community-contributed skins — visual themes that change the app's
accent colors, background gradient, and surface tinting. Think of it like
[Winamp skins](https://skins.webamp.org/) but for a calendar app.

## Quick Start

1. **Copy the template**

   ```
   cp Bubo/Skins/TEMPLATE.swift Bubo/Skins/YourSkinName.swift
   ```

2. **Uncomment and fill in the values** — each field is documented in the
   template. The key properties:

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

3. **Register your skin** — open `Bubo/Skins/SkinDefinition.swift` and add
   your skin to the `allSkins` array:

   ```swift
   static let allSkins: [SkinDefinition] = [
       classic,
       ampGreen,
       // ...existing skins...
       yourSkinName,  // ← add here
   ]
   ```

4. **Open a PR** with your new skin file + the catalog edit. That's it!

## Design Tips

- **Accent color**: Pick one strong, saturated color. This drives the entire
  visual identity.
- **Surface tint**: Use a very dark, desaturated version of your accent. High
  opacity here overwhelms the UI — keep it subtle (0.2–0.35).
- **Background gradient**: Use 2–3 stops fading to `.clear`. Opacity should be
  0.10–0.25 so the gradient doesn't overpower content.
- **Preview colors**: The first color should be your accent; the second a
  complementary dark tone.
- **Test both light & dark mode** — skins use adaptive blend modes that work in
  both, but some color combos look better in one mode.

## File Structure

```
Bubo/Skins/
├── SkinDefinition.swift   # Core struct + catalog registry
├── TEMPLATE.swift         # Copy this to start a new skin
├── System.swift           # Pure macOS system appearance
├── Classic.swift          # Default (no tinting)
├── AmpGreen.swift         # Winamp classic green
├── PalmBeach.swift        # Tropical coral
├── ToonPop.swift          # Cartoon bold
├── SlimDark.swift         # Moody purple
├── CyberNeon.swift        # Cyberpunk cyan
├── SunsetRider.swift      # Warm sunset
├── RetroTerminal.swift    # Matrix green
└── Bubblegum.swift        # Pink candy
```

## Rules

- **Skin IDs are permanent** — once merged, never rename the `id` field.
  Users' settings reference this string.
- **One file per skin** — keeps diffs clean and avoids merge conflicts.
- **No code outside your extension** — skins are pure data. Don't add view
  modifiers, new components, or other logic in your skin file.
- **Use `Color(red:green:blue:)` for custom colors** — avoid named colors like
  `.blue` since they vary across macOS versions.
- **Keep the file header comment** with your name and a brief description.

## Gradient Styles

Two gradient styles are available:

```swift
// Linear — flows between two corners/edges
.linear(startPoint: .topLeading, endPoint: .bottomTrailing)

// Radial — radiates from a center point
.radial(center: .top, startRadius: 0, endRadius: 500)
```

Common `UnitPoint` values: `.top`, `.bottom`, `.topLeading`, `.topTrailing`,
`.bottomLeading`, `.bottomTrailing`, `.center`.

## Custom Skins (no PR needed)

You can also create skins as `.buboskin` JSON files and import them directly
in **Settings → Skin → Import .buboskin file**. No code, no Xcode, no PR.

### Quick start

1. Copy `Bubo/Skins/TEMPLATE.buboskin` and rename it (e.g. `MyTheme.buboskin`)
2. Edit the JSON values — same properties as the Swift skins
3. Open Bubo → Settings → Skin → **Import .buboskin file** and select your file
4. Your skin appears in the picker immediately

### JSON format

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

Colors use `red`, `green`, `blue` (0.0–1.0) with an optional `opacity`.
Gradient style is `"linear"` or `"radial"`. Button style is `"solid"`,
`"gradient"`, or `"glass"`.

### Background images

Users can set a custom background image for any skin directly in Settings.
Select a skin, then use the "Choose image..." button to pick a photo.
Opacity and blur can be adjusted per skin.

Skins are stored in `~/Library/Application Support/Bubo/Skins/`. You can
also drop `.buboskin` files there directly and restart Bubo.

Right-click a community skin in the picker to remove it.

## Example

See any existing skin file (e.g., `AmpGreen.swift`) for a complete working
example, or `TEMPLATE.buboskin` for the JSON format.
