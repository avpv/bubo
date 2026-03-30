import Foundation
import SwiftUI

// MARK: - Custom Skin JSON Format

/// JSON-serializable representation of a Bubo skin.
///
/// Users create `.buboskin` files (JSON) with this structure and import them
/// via Settings, just like Winamp `.wsz` skins — no code changes or PRs needed.
///
/// Example `.buboskin` file:
/// ```json
/// {
///   "id": "my_cool_skin",
///   "displayName": "My Cool Skin",
///   "author": "@username",
///   "accentColor": { "red": 0.0, "green": 0.9, "blue": 0.0 },
///   "surfaceTint": { "red": 0.0, "green": 0.15, "blue": 0.0 },
///   "surfaceTintOpacity": 0.35,
///   "backgroundGradient": {
///     "colors": [
///       { "red": 0.0, "green": 0.18, "blue": 0.0, "opacity": 0.5 },
///       { "red": 0.0, "green": 0.08, "blue": 0.0, "opacity": 0.3 },
///       { "red": 0.0, "green": 0.0, "blue": 0.0, "opacity": 0.0 }
///     ],
///     "style": "linear",
///     "startPoint": "topLeading",
///     "endPoint": "bottomTrailing"
///   },
///   "previewColors": [
///     { "red": 0.0, "green": 0.7, "blue": 0.0 },
///     { "red": 0.1, "green": 0.2, "blue": 0.1 }
///   ],
///   "prefersDarkTint": true,
///   "secondaryAccent": { "red": 0.0, "green": 0.65, "blue": 0.15 },
///   "buttonStyle": "gradient",
///   "buttonShape": "capsule",
///   "buttonColor": { "red": 1.0, "green": 1.0, "blue": 1.0 },
///   "buttonMaterial": "regular",
///   "buttonTint": { "red": 0.0, "green": 0.4, "blue": 0.8 },
///   "buttonTintOpacity": 0.3,
///   "toolbarTint": { "red": 0.3, "green": 0.5, "blue": 0.4 },
///   "barMaterial": "thick",
///   "barTint": { "red": 0.0, "green": 0.2, "blue": 0.4 },
///   "barTintOpacity": 0.15,
///   "platterMaterial": "regular",
///   "platterTint": { "red": 0.0, "green": 0.1, "blue": 0.2 },
///   "platterTintOpacity": 0.1
/// }
/// ```
struct CustomSkinJSON: Codable {
    let id: String
    let displayName: String
    let author: String
    let accentColor: JSONColor
    let surfaceTint: JSONColor
    let surfaceTintOpacity: Double
    let backgroundGradient: JSONGradient
    let previewColors: [JSONColor]
    let prefersDarkTint: Bool
    let secondaryAccent: JSONColor?
    let buttonStyle: String?

    /// Button clip shape. Values: "capsule" (default), "roundedRect", "rectangle".
    let buttonShape: String?

    /// Explicit foreground color for primary buttons. Overrides auto-contrast logic.
    let buttonColor: JSONColor?

    /// Material used as the base for glass-style and secondary buttons.
    /// Same values as barMaterial. Defaults to "regular".
    let buttonMaterial: String?

    /// Optional color overlay on button material (glass-style). Falls back to accentColor.
    let buttonTint: JSONColor?

    /// Opacity of button tint overlay (0–1, typically 0.15–0.35). Defaults to 0.3.
    let buttonTintOpacity: Double?

    /// Toolbar button tint color (Refresh, Settings, Quit).
    /// Apple HIG: secondary actions use a subtler color for visual hierarchy.
    let toolbarTint: JSONColor?

    /// Material for header/footer bars.
    /// Valid values: "ultraThin", "thin", "regular", "thick", "ultraThick", "bar".
    /// Apple HIG: controls translucency level of toolbar areas. Defaults to "thick".
    let barMaterial: String?

    /// Optional color overlay on top of bar material — creates a tinted-glass effect.
    let barTint: JSONColor?

    /// Opacity of the bar tint overlay (0–1, typically 0.05–0.25). Defaults to 0.
    let barTintOpacity: Double?

    /// Material for card/platter surfaces. Same values as barMaterial. Defaults to "regular".
    let platterMaterial: String?

    /// Optional color overlay on platter surfaces.
    let platterTint: JSONColor?

    /// Opacity of the platter tint overlay (0–1, typically 0.05–0.2). Defaults to 0.
    let platterTintOpacity: Double?

    // MARK: Typography & Symbols (HIG 2026)

    /// Font design: "default", "rounded", "serif", "monospaced". Defaults to "rounded".
    let fontDesign: String?

    /// Font weight for body/buttons: "regular", "medium", "semibold", "bold". Defaults to "semibold".
    let fontWeight: String?

    /// Font weight for headlines. Same values as fontWeight. Defaults to "semibold".
    let headlineFontWeight: String?

    /// SF Symbol rendering: "monochrome", "hierarchical", "palette", "multicolor". Defaults to "hierarchical".
    let sfSymbolRendering: String?

    /// SF Symbol weight: "ultraLight"–"black". Defaults to "medium".
    let sfSymbolWeight: String?

    /// Badge style: "filled", "outlined", "tinted". Defaults to "tinted".
    let badgeStyle: String?

    /// Separator style: "system", "subtle", "accent", "none". Defaults to "system".
    let separatorStyle: String?

    /// Separator opacity (0–1). Floor at 0.15 when separatorStyle != "none". Defaults to 0.5.
    let separatorOpacity: Double?

    func toSkinDefinition(skinFileURL: URL? = nil, isBuiltIn: Bool = false) -> SkinDefinition {
        // HIG: Validate accent color contrast — warn if luminance is too high
        // for white button text (WCAG 2.1 AA requires 4.5:1 contrast ratio)
        if accentColor.name == nil {
            let accentLuminance = 0.2126 * (accentColor.red ?? 0) + 0.7152 * (accentColor.green ?? 0) + 0.0722 * (accentColor.blue ?? 0)
            if accentLuminance > 0.55 {
                print("[Bubo] Warning: Skin '\(displayName)' accent color has high luminance (\(String(format: "%.2f", accentLuminance))). Button text may have insufficient contrast per Apple HIG.")
            }
        }

        return SkinDefinition(
            id: isBuiltIn ? id : "custom_\(id)",
            displayName: displayName,
            author: author,
            accentColor: accentColor.toColor(),
            surfaceTint: surfaceTint.toColor(),
            surfaceTintOpacity: surfaceTintOpacity,
            backgroundGradient: backgroundGradient.toSkinGradient(),
            previewColors: previewColors.map { $0.toColor() },
            prefersDarkTint: prefersDarkTint,
            secondaryAccent: secondaryAccent?.toColor(),
            buttonStyle: resolvedButtonStyle,
            buttonShape: resolvedButtonShape,
            buttonColor: buttonColor?.toColor(),
            buttonMaterial: resolvedButtonMaterial,
            buttonTint: buttonTint?.toColor(),
            buttonTintOpacity: buttonTintOpacity ?? 0.3,
            toolbarTint: toolbarTint?.toColor(),
            barMaterial: resolvedBarMaterial,
            barTint: barTint?.toColor(),
            barTintOpacity: barTintOpacity ?? 0,
            platterMaterial: resolvedPlatterMaterial,
            platterTint: platterTint?.toColor(),
            platterTintOpacity: platterTintOpacity ?? 0,
            fontDesign: resolvedFontDesign,
            fontWeight: resolvedFontWeight,
            headlineFontWeight: resolvedHeadlineFontWeight,
            sfSymbolRendering: resolvedSymbolRendering,
            sfSymbolWeight: resolvedSymbolWeight,
            badgeStyle: resolvedBadgeStyle,
            separatorStyle: resolvedSeparatorStyle,
            separatorOpacity: separatorOpacity ?? 0.5
        )
    }

    private var resolvedButtonStyle: SkinButtonStyle {
        switch buttonStyle?.lowercased() {
        case "solid": .solid
        case "glass": .glass
        default: .gradient
        }
    }

    private var resolvedButtonShape: SkinButtonShape {
        guard let value = buttonShape else { return .capsule }
        if let exact = SkinButtonShape(rawValue: value) { return exact }
        let lower = value.lowercased()
        return SkinButtonShape.allCases.first { $0.rawValue.lowercased() == lower } ?? .capsule
    }

    private var resolvedButtonMaterial: SkinBarMaterial {
        guard let value = buttonMaterial else { return .regular }
        if let exact = SkinBarMaterial(rawValue: value) { return exact }
        let lower = value.lowercased()
        return SkinBarMaterial.allCases.first { $0.rawValue.lowercased() == lower } ?? .regular
    }

    private var resolvedPlatterMaterial: SkinBarMaterial {
        guard let value = platterMaterial else { return .regular }
        if let exact = SkinBarMaterial(rawValue: value) { return exact }
        let lower = value.lowercased()
        return SkinBarMaterial.allCases.first { $0.rawValue.lowercased() == lower } ?? .regular
    }

    private var resolvedFontDesign: SkinFontDesign {
        guard let value = fontDesign else { return .rounded }
        return SkinFontDesign(rawValue: value)
            ?? SkinFontDesign.allCases.first { $0.rawValue.lowercased() == value.lowercased() }
            ?? .rounded
    }

    private var resolvedFontWeight: SkinFontWeight {
        guard let value = fontWeight else { return .semibold }
        return SkinFontWeight(rawValue: value)
            ?? SkinFontWeight.allCases.first { $0.rawValue.lowercased() == value.lowercased() }
            ?? .semibold
    }

    private var resolvedHeadlineFontWeight: SkinFontWeight {
        guard let value = headlineFontWeight else { return .semibold }
        return SkinFontWeight(rawValue: value)
            ?? SkinFontWeight.allCases.first { $0.rawValue.lowercased() == value.lowercased() }
            ?? .semibold
    }

    private var resolvedSymbolRendering: SkinSymbolRendering {
        guard let value = sfSymbolRendering else { return .hierarchical }
        return SkinSymbolRendering(rawValue: value)
            ?? SkinSymbolRendering.allCases.first { $0.rawValue.lowercased() == value.lowercased() }
            ?? .hierarchical
    }

    private var resolvedSymbolWeight: SkinSymbolWeight {
        guard let value = sfSymbolWeight else { return .medium }
        let resolved = SkinSymbolWeight(rawValue: value)
            ?? SkinSymbolWeight.allCases.first { $0.rawValue.lowercased() == value.lowercased() }
            ?? .medium
        // HIG 2026: warn if symbol weight diverges > 2 steps from font weight
        let fontIdx = resolvedFontWeight.swiftUIWeight == .regular ? 3
            : resolvedFontWeight.swiftUIWeight == .medium ? 4
            : resolvedFontWeight.swiftUIWeight == .semibold ? 5
            : 6 // bold
        let delta = abs(resolved.weightIndex - fontIdx)
        if delta > 2 {
            print("[Bubo] Warning: Skin '\(displayName)' sfSymbolWeight (\(value)) diverges > 2 steps from fontWeight. HIG recommends matching symbol and text weights.")
        }
        return resolved
    }

    private var resolvedBadgeStyle: SkinBadgeStyle {
        guard let value = badgeStyle else { return .tinted }
        return SkinBadgeStyle(rawValue: value)
            ?? SkinBadgeStyle.allCases.first { $0.rawValue.lowercased() == value.lowercased() }
            ?? .tinted
    }

    private var resolvedSeparatorStyle: SkinSeparatorStyle {
        guard let value = separatorStyle else { return .system }
        return SkinSeparatorStyle(rawValue: value)
            ?? SkinSeparatorStyle.allCases.first { $0.rawValue.lowercased() == value.lowercased() }
            ?? .system
    }

    private var resolvedBarMaterial: SkinBarMaterial {
        guard let value = barMaterial else { return .thick }
        // Try exact match first, then case-insensitive lookup
        if let exact = SkinBarMaterial(rawValue: value) { return exact }
        let lower = value.lowercased()
        return SkinBarMaterial.allCases.first { $0.rawValue.lowercased() == lower } ?? .thick
    }
}

/// A flexible color type that decodes from multiple JSON representations.
///
/// **Supported formats** (all fields that expect a color accept any of these):
///
/// | Format | Example | Notes |
/// |--------|---------|-------|
/// | Hex RGB | `"#0070FA"` | 6-digit hex, opacity = 1.0 |
/// | Hex RGBA | `"#0070FA80"` | 8-digit hex, last byte = alpha |
/// | Named color | `"accentColor"` | System/semantic color |
/// | Named + opacity | `"accentColor:0.5"` | Named color at 50% opacity |
/// | Keyword | `"clear"`, `"white"`, `"black"` | Common colors |
/// | Legacy object | `{ "red": 0.0, "green": 0.44, "blue": 0.98 }` | Backward compat |
/// | Legacy named | `{ "name": "accentColor", "opacity": 0.5 }` | Backward compat |
struct JSONColor: Codable {
    var red: Double?
    var green: Double?
    var blue: Double?
    var opacity: Double?
    var name: String?

    private enum CodingKeys: String, CodingKey {
        case red, green, blue, opacity, name
    }

    init(from decoder: Decoder) throws {
        // 1. Try string first (new short format)
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self) {
            self = JSONColor.parse(string)
            return
        }

        // 2. Fall back to keyed container (legacy object format)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        red = try container.decodeIfPresent(Double.self, forKey: .red)
        green = try container.decodeIfPresent(Double.self, forKey: .green)
        blue = try container.decodeIfPresent(Double.self, forKey: .blue)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }

    func encode(to encoder: Encoder) throws {
        // Prefer short string form when encoding
        if let name {
            var container = encoder.singleValueContainer()
            if let opacity {
                try container.encode("\(name):\(opacity)")
            } else {
                try container.encode(name)
            }
            return
        }
        if let r = red, let g = green, let b = blue {
            var container = encoder.singleValueContainer()
            let ri = Int(round(r * 255)), gi = Int(round(g * 255)), bi = Int(round(b * 255))
            if let a = opacity, a < 1.0 {
                let ai = Int(round(a * 255))
                try container.encode(String(format: "#%02X%02X%02X%02X", ri, gi, bi, ai))
            } else {
                try container.encode(String(format: "#%02X%02X%02X", ri, gi, bi))
            }
            return
        }
        // Fallback: encode as object
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(red, forKey: .red)
        try container.encodeIfPresent(green, forKey: .green)
        try container.encodeIfPresent(blue, forKey: .blue)
        try container.encodeIfPresent(opacity, forKey: .opacity)
        try container.encodeIfPresent(name, forKey: .name)
    }

    // MARK: - String Parsing

    /// Parse a color string: hex (`#RRGGBB`, `#RRGGBBAA`), named (`"accentColor"`),
    /// or named with opacity (`"accentColor:0.5"`).
    private static func parse(_ string: String) -> JSONColor {
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        // Hex color
        if trimmed.hasPrefix("#") {
            return parseHex(trimmed)
        }

        // Named color with opacity: "accentColor:0.5"
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            return JSONColor(
                red: nil, green: nil, blue: nil,
                opacity: Double(parts[1]),
                name: String(parts[0])
            )
        }

        // Plain named color
        return JSONColor(red: nil, green: nil, blue: nil, opacity: nil, name: trimmed)
    }

    private static func parseHex(_ hex: String) -> JSONColor {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }

        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)

        if h.count == 8 {
            // #RRGGBBAA
            return JSONColor(
                red: Double((int >> 24) & 0xFF) / 255.0,
                green: Double((int >> 16) & 0xFF) / 255.0,
                blue: Double((int >> 8) & 0xFF) / 255.0,
                opacity: Double(int & 0xFF) / 255.0,
                name: nil
            )
        } else {
            // #RRGGBB
            return JSONColor(
                red: Double((int >> 16) & 0xFF) / 255.0,
                green: Double((int >> 8) & 0xFF) / 255.0,
                blue: Double(int & 0xFF) / 255.0,
                opacity: nil,
                name: nil
            )
        }
    }

    // MARK: - To SwiftUI Color

    func toColor() -> Color {
        if let name {
            let base: Color = switch name.lowercased() {
            case "accentcolor":             .accentColor
            case "clear", "transparent":    .clear
            case "gray", "grey":            .gray
            case "white":                   .white
            case "black":                   .black
            default:                        .accentColor
            }
            if let opacity { return base.opacity(opacity) }
            return base
        }
        let color = Color(red: red ?? 0, green: green ?? 0, blue: blue ?? 0)
        if let opacity { return color.opacity(opacity) }
        return color
    }
}

struct JSONGradient: Codable {
    var colors: [JSONColor]?
    var style: String?  // "linear", "radial", or "clear"
    // Linear
    var startPoint: String?
    var endPoint: String?
    // Radial
    var center: String?
    var startRadius: CGFloat?
    var endRadius: CGFloat?

    func toSkinGradient() -> SkinGradient {
        let styleValue = style ?? "clear"
        if styleValue.lowercased() == "clear" || (colors ?? []).isEmpty {
            return .clear
        }
        let swiftColors = (colors ?? []).map { $0.toColor() }
        let gradientStyle: SkinGradient.Style
        if styleValue.lowercased() == "radial" {
            gradientStyle = .radial(
                center: unitPoint(from: center ?? "top"),
                startRadius: startRadius ?? 0,
                endRadius: endRadius ?? 500
            )
        } else {
            gradientStyle = .linear(
                startPoint: unitPoint(from: startPoint ?? "topLeading"),
                endPoint: unitPoint(from: endPoint ?? "bottomTrailing")
            )
        }
        return SkinGradient(colors: swiftColors, style: gradientStyle)
    }

    private func unitPoint(from name: String) -> UnitPoint {
        switch name.lowercased() {
        case "top": .top
        case "bottom": .bottom
        case "leading": .leading
        case "trailing": .trailing
        case "topleading": .topLeading
        case "toptrailing": .topTrailing
        case "bottomleading": .bottomLeading
        case "bottomtrailing": .bottomTrailing
        case "center": .center
        default: .center
        }
    }
}

// MARK: - Custom Skin Loader

/// Manages loading, importing, and removing custom `.buboskin` files.
///
/// Skins are stored in `~/Library/Application Support/Bubo/Skins/`.
@Observable
class CustomSkinLoader {
    static let shared = CustomSkinLoader()

    private(set) var customSkins: [SkinDefinition] = []
    private let fileManager = FileManager.default

    private var skinsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Bubo/Skins", isDirectory: true)
    }

    init() {
        ensureSkinsDirectory()
        loadAll()
    }

    /// Reload all custom skins from disk.
    func loadAll() {
        ensureSkinsDirectory()
        var loaded: [SkinDefinition] = []

        guard let files = try? fileManager.contentsOfDirectory(
            at: skinsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.pathExtension == "buboskin" {
            if let skin = loadSkin(from: file) {
                loaded.append(skin)
            }
        }

        customSkins = loaded.sorted { $0.displayName < $1.displayName }
    }

    /// Import a `.buboskin` file by copying it into the skins directory.
    /// Returns the skin definition if successful.
    @discardableResult
    func importSkin(from sourceURL: URL) -> SkinDefinition? {
        ensureSkinsDirectory()
        let destination = skinsDirectory.appendingPathComponent(sourceURL.lastPathComponent)

        // Remove existing file with the same name
        try? fileManager.removeItem(at: destination)

        do {
            // Handle security-scoped resources (file picked via NSOpenPanel)
            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            return nil
        }

        guard let skin = loadSkin(from: destination) else {
            // Invalid file — clean up
            try? fileManager.removeItem(at: destination)
            return nil
        }

        loadAll()
        return skin
    }

    /// Remove a custom skin by ID.
    func removeSkin(id: String) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: skinsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.pathExtension == "buboskin" {
            if let data = try? Data(contentsOf: file),
               let json = try? JSONDecoder().decode(CustomSkinJSON.self, from: data),
               "custom_\(json.id)" == id {
                try? fileManager.removeItem(at: file)
                break
            }
        }

        loadAll()
    }

    /// Open the skins folder in Finder.
    func revealInFinder() {
        ensureSkinsDirectory()
        NSWorkspace.shared.open(skinsDirectory)
    }

    // MARK: - Private

    private func ensureSkinsDirectory() {
        try? fileManager.createDirectory(at: skinsDirectory, withIntermediateDirectories: true)
    }

    private func loadSkin(from url: URL) -> SkinDefinition? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode(CustomSkinJSON.self, from: data)
        else { return nil }
        return json.toSkinDefinition(skinFileURL: url)
    }
}

// MARK: - Built-In Skin Loader

/// Loads built-in skins from bundled `.buboskin` JSON files in the app's
/// `BuiltInSkins` resource directory. This gives built-in skins the same
/// JSON-based configuration as custom skins — a unified approach.
///
/// If no JSON files can be found or all fail to decode, a hardcoded
/// fallback Classic skin is returned so the app never launches with zero skins.
enum BuiltInSkinLoader {
    /// All built-in skins loaded from bundled JSON files.
    /// Order is determined by the `order` array; skins not listed appear at the end.
    /// Guaranteed to contain at least one skin (Classic fallback).
    static let skins: [SkinDefinition] = {
        let loaded = loadBuiltInSkins()
        if loaded.isEmpty {
            print("[Bubo] Warning: No built-in skins loaded from JSON. Using hardcoded Classic fallback.")
            return [fallbackClassic]
        }
        return loaded
    }()

    /// Preferred display order (by skin ID).
    private static let order = [
        "system", "classic", "graphite", "ocean", "lavender",
        "rose_gold", "midnight", "sierra", "arctic", "sage",
        "win_xp_blue", "win_xp_olive", "win_xp_silver",
    ]

    /// Hardcoded fallback so the app always has at least one skin,
    /// even if the bundle is misconfigured or all JSON files are corrupt.
    private static let fallbackClassic = SkinDefinition(
        id: "classic",
        displayName: "Classic",
        author: "Bubo",
        accentColor: .accentColor,
        surfaceTint: .clear,
        surfaceTintOpacity: 0,
        backgroundGradient: .clear,
        previewColors: [.gray],
        prefersDarkTint: false,
        buttonStyle: .solid,
        fontDesign: .default,
        fontWeight: .regular,
        headlineFontWeight: .medium,
        sfSymbolRendering: .monochrome,
        sfSymbolWeight: .regular
    )

    private static func loadBuiltInSkins() -> [SkinDefinition] {
        let urls = findBuiltInSkinURLs()
        if urls.isEmpty {
            print("[Bubo] Warning: No built-in skin files found.")
            return []
        }

        var loaded: [SkinDefinition] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else {
                print("[Bubo] Warning: Cannot read built-in skin file \(url.lastPathComponent)")
                continue
            }
            guard let json = try? JSONDecoder().decode(CustomSkinJSON.self, from: data) else {
                print("[Bubo] Warning: Invalid JSON in built-in skin \(url.lastPathComponent)")
                continue
            }
            loaded.append(json.toSkinDefinition(skinFileURL: url, isBuiltIn: true))
        }

        // Sort by preferred order
        return loaded.sorted { a, b in
            let idxA = order.firstIndex(of: a.id) ?? Int.max
            let idxB = order.firstIndex(of: b.id) ?? Int.max
            return idxA < idxB
        }
    }

    /// Searches multiple locations for built-in skin files:
    /// 1. Bundle resources with "BuiltInSkins" subdirectory (standard Xcode setup)
    /// 2. Bundle resources at top level (flat resource copy)
    /// 3. "BuiltInSkins" directory next to the executable (dev/debug builds)
    private static func findBuiltInSkinURLs() -> [URL] {
        // 1. Standard: bundled with subdirectory
        if let urls = Bundle.main.urls(forResourcesWithExtension: "buboskin", subdirectory: "BuiltInSkins"),
           !urls.isEmpty {
            return urls
        }

        // 2. Flat bundle resources (no subdirectory — files copied to Resources root)
        if let resourceURL = Bundle.main.resourceURL {
            let builtInDir = resourceURL.appendingPathComponent("BuiltInSkins", isDirectory: true)
            if let urls = try? FileManager.default.contentsOfDirectory(at: builtInDir, includingPropertiesForKeys: nil),
               !urls.filter({ $0.pathExtension == "buboskin" }).isEmpty {
                return urls.filter { $0.pathExtension == "buboskin" }
            }
        }

        // 3. Next to executable (development builds, SPM)
        let executableURL = Bundle.main.executableURL?.deletingLastPathComponent()
        if let execDir = executableURL {
            let devDir = execDir.appendingPathComponent("BuiltInSkins", isDirectory: true)
            if let urls = try? FileManager.default.contentsOfDirectory(at: devDir, includingPropertiesForKeys: nil),
               !urls.filter({ $0.pathExtension == "buboskin" }).isEmpty {
                return urls.filter { $0.pathExtension == "buboskin" }
            }
        }

        return []
    }
}
