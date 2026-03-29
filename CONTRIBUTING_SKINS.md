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

## Example

See any existing skin file (e.g., `AmpGreen.swift`) for a complete working
example.
