import Foundation
import SwiftUI
import os

// MARK: - Skin JSON Format

/// JSON-serializable representation of a Bubo skin.
///
/// Both built-in and custom skins use the same `.json` JSON format.
/// Colors are strings: hex (`"#0070FA"`), named (`"accentColor"`),
/// named with opacity (`"accentColor:0.5"`), or keyword (`"clear"`).
///
/// Keep the required set minimal. A skin author should think about **mood**
/// (accent, background, light/dark), not about shadow radii or symbol
/// weights. Everything absent falls back to a sensible default baked into
/// `SkinDefinition`. The canonical list of allowed fields is
/// `buboskin.schema.json` — it rejects unknown keys.
///
/// Minimal example:
/// ```json
/// {
///   "id": "my_cool_skin",
///   "displayName": "My Cool Skin",
///   "author": "@username",
///   "accentColor": "#00E600",
///   "prefersDarkTint": true,
///   "backgroundGradient": {
///     "colors": ["#002E0080", "#001A0D4C", "clear"],
///     "style": "linear",
///     "startPoint": "topLeading",
///     "endPoint": "bottomTrailing"
///   },
///   "previewColors": ["#00B200", "#1A3319"]
/// }
/// ```
struct CustomSkinJSON: Codable {
    // MARK: Identity
    let id: String
    let displayName: String
    let author: String

    // MARK: Mood (required)
    let accentColor: JSONColor
    let prefersDarkTint: Bool
    let backgroundGradient: JSONGradient
    let previewColors: [JSONColor]

    // MARK: Mood (optional)
    let secondaryAccent: JSONColor?
    /// `"auto"` (default, follow system) / `"light"` / `"dark"`. Controls
    /// how this skin reconciles its mood with `@Environment(\.colorScheme)`.
    let darkMoodMode: String?

    // MARK: Surface tints (optional)
    let barTint: JSONColor?
    let barTintOpacity: Double?
    let platterTint: JSONColor?
    let platterTintOpacity: Double?

    // MARK: Buttons (optional)
    let buttonStyle: String?
    let buttonShape: String?
    let buttonColor: JSONColor?
    let buttonAccentColor: JSONColor?
    let buttonSecondaryAccent: JSONColor?
    let buttonTint: JSONColor?

    // MARK: Typography (optional)
    let fontWeight: String?
    let fontDesign: String?

    // MARK: Appearance (optional)
    let badgeStyle: String?
    let separatorStyle: String?

    func toSkinDefinition(skinFileURL: URL? = nil, isBuiltIn: Bool = false) -> SkinDefinition {
        SkinDefinition(
            id: isBuiltIn ? id : "custom_\(id)",
            displayName: displayName,
            author: author,
            accentColor: accentColor.toColor(),
            prefersDarkTint: prefersDarkTint,
            darkMoodMode: resolvedDarkMoodMode,
            backgroundGradient: backgroundGradient.toSkinGradient(),
            previewColors: previewColors.map { $0.toColor() },
            secondaryAccent: secondaryAccent?.toColor(),
            barTint: barTint?.toColor(),
            barTintOpacity: barTintOpacity ?? 0.08,
            platterTint: platterTint?.toColor(),
            platterTintOpacity: platterTintOpacity ?? 0.05,
            buttonStyle: resolvedButtonStyle,
            buttonShape: resolvedButtonShape,
            buttonColor: buttonColor?.toColor(),
            buttonAccentColor: buttonAccentColor?.toColor(),
            buttonSecondaryAccent: buttonSecondaryAccent?.toColor(),
            buttonTint: buttonTint?.toColor(),
            fontWeight: resolvedFontWeight,
            fontDesign: resolvedFontDesign,
            badgeStyle: resolvedBadgeStyle,
            separatorStyle: resolvedSeparatorStyle
        )
    }

    /// HIG: Validate accent color contrast ratio against white (3:1 minimum).
    func validateContrastRatio() {
        let color = accentColor.toColor()
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let r = nsColor.redComponent
        let g = nsColor.greenComponent
        let b = nsColor.blueComponent

        func linearize(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let lum = 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
        let whiteLum: CGFloat = 1.0
        let ratio = (whiteLum + 0.05) / (lum + 0.05)

        if ratio < 3.0 {
            skinLogger.warning("Skin '\(displayName)' accentColor contrast ratio is \(String(format: "%.2f", ratio)):1 (minimum 3:1 per Apple HIG). Consider darkening the accent color.")
        }
    }

    // MARK: - Defaults

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

    private var resolvedDarkMoodMode: SkinDarkMoodMode {
        guard let value = darkMoodMode?.lowercased() else { return .auto }
        return SkinDarkMoodMode(rawValue: value) ?? .auto
    }

    private var resolvedFontWeight: SkinFontWeight {
        guard let value = fontWeight else { return .regular }
        // Apple's design system forbids weight 500 — legacy custom skins
        // that still declare `"medium"` are migrated to `.regular` at
        // load-time so users can update their files at their own pace
        // without the skin disappearing from the picker.
        if value.lowercased() == "medium" { return .regular }
        return SkinFontWeight(rawValue: value)
            ?? SkinFontWeight.allCases.first { $0.rawValue.lowercased() == value.lowercased() }
            ?? .regular
    }

    private var resolvedFontDesign: SkinFontDesign {
        guard let value = fontDesign else { return .rounded }
        return SkinFontDesign(rawValue: value)
            ?? SkinFontDesign.allCases.first { $0.rawValue.lowercased() == value.lowercased() }
            ?? .rounded
    }

    private var resolvedBadgeStyle: SkinBadgeStyle {
        guard let value = badgeStyle else { return .tinted }
        return SkinBadgeStyle(rawValue: value)
            ?? SkinBadgeStyle.allCases.first { $0.rawValue.lowercased() == value.lowercased() }
            ?? .tinted
    }

    private var resolvedSeparatorStyle: SkinSeparatorStyle {
        guard let value = separatorStyle else { return .subtle }
        return SkinSeparatorStyle(rawValue: value)
            ?? SkinSeparatorStyle.allCases.first { $0.rawValue.lowercased() == value.lowercased() }
            ?? .subtle
    }
}

/// A color string that decodes from JSON.
///
/// **Supported formats:**
///
/// | Format | Example | Notes |
/// |--------|---------|-------|
/// | Hex RGB | `"#0070FA"` | 6-digit hex, fully opaque |
/// | Hex RGBA | `"#0070FA80"` | 8-digit hex, last byte = alpha |
/// | Named color | `"accentColor"` | System/semantic color |
/// | Named + opacity | `"accentColor:0.5"` | Named color at 50% opacity |
/// | Keyword | `"clear"`, `"white"`, `"black"`, `"gray"` | Common colors |
struct JSONColor: Codable {
    private let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    // MARK: - To SwiftUI Color

    func toColor() -> Color {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        // Hex color
        if trimmed.hasPrefix("#") {
            return hexToColor(trimmed)
        }

        // Named color with opacity: "accentColor:0.5"
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            let base = namedColor(String(parts[0]))
            if let opacity = Double(parts[1]) {
                return base.opacity(opacity)
            }
            return base
        }

        // Plain named color
        return namedColor(trimmed)
    }

    // MARK: - Private

    private func namedColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "accentcolor":          .accentColor
        case "clear", "transparent": .clear
        case "gray", "grey":         .gray
        case "white":                .white
        case "black":                .black
        default:                     .accentColor
        }
    }

    private func hexToColor(_ hex: String) -> Color {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }

        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)

        if h.count == 8 {
            // #RRGGBBAA
            let r = Double((int >> 24) & 0xFF) / 255.0
            let g = Double((int >> 16) & 0xFF) / 255.0
            let b = Double((int >> 8) & 0xFF) / 255.0
            let a = Double(int & 0xFF) / 255.0
            return Color(red: r, green: g, blue: b).opacity(a)
        } else {
            // #RRGGBB
            let r = Double((int >> 16) & 0xFF) / 255.0
            let g = Double((int >> 8) & 0xFF) / 255.0
            let b = Double(int & 0xFF) / 255.0
            return Color(red: r, green: g, blue: b)
        }
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

/// Manages loading, importing, and removing custom `.json` files.
///
/// Skins are stored in `~/Library/Application Support/Bubo/Skins/`.
private let skinLogger = Logger(subsystem: "com.avpv.Bubo", category: "SkinLoader")

@Observable
class CustomSkinLoader {
    static let shared = CustomSkinLoader()

    private(set) var customSkins: [SkinDefinition] = []
    private let fileManager = FileManager.default

    private var skinsDirectory: URL {
        // `URL.applicationSupportDirectory` is guaranteed to exist by the
        // platform, unlike `urls(for:in:).first` which the type system claims
        // is optional and therefore force-unwraps were a latent crash.
        URL.applicationSupportDirectory.appendingPathComponent("Bubo/Skins", isDirectory: true)
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

        for file in files where file.pathExtension == "json" {
            if let skin = loadSkin(from: file) {
                loaded.append(skin)
            }
        }

        customSkins = loaded.sorted { $0.displayName < $1.displayName }
    }

    /// Import a `.json` file by copying it into the skins directory.
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

        for file in files where file.pathExtension == "json" {
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
        // HIG: Validate custom skin contrast ratios on load
        json.validateContrastRatio()
        return json.toSkinDefinition(skinFileURL: url)
    }
}

// MARK: - Built-In Skin Loader

/// Loads built-in skins from bundled `.json` JSON files in the app's
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
            skinLogger.warning("No built-in skins loaded from JSON. Using hardcoded Classic fallback.")
            return [fallbackClassic]
        }
        return loaded
    }()

    /// Preferred display order (by skin ID).
    private static let order = [
        "classic", "system", "apple", "graphite", "ocean", "lavender",
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
        prefersDarkTint: false,
        backgroundGradient: .clear,
        previewColors: [.gray],
        buttonStyle: .solid,
        buttonShape: .roundedRect
    )

    private static func loadBuiltInSkins() -> [SkinDefinition] {
        let urls = findBuiltInSkinURLs()
        if urls.isEmpty {
            skinLogger.warning("No built-in skin files found.")
            return []
        }

        var loaded: [SkinDefinition] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else {
                skinLogger.warning("Cannot read built-in skin file \(url.lastPathComponent)")
                continue
            }
            guard let json = try? JSONDecoder().decode(CustomSkinJSON.self, from: data) else {
                skinLogger.warning("Invalid JSON in built-in skin \(url.lastPathComponent)")
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
    /// 1. SPM resource bundle (Bubo_Bubo.bundle)
    /// 2. Bundle resources with "BuiltInSkins" subdirectory (standard Xcode setup)
    /// 3. Bundle resources at top level (flat resource copy)
    /// 4. "BuiltInSkins" directory next to the executable (dev/debug builds)
    private static func findBuiltInSkinURLs() -> [URL] {
        // 1. SPM resource bundle
        if let moduleBundle = Bundle.safeModule {
            // SPM .copy preserves directory name inside the resource bundle
            let builtInDir = moduleBundle.resourceURL?.appendingPathComponent("BuiltInSkins", isDirectory: true)
            if let dir = builtInDir,
               let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
               !urls.filter({ $0.pathExtension == "json" }).isEmpty {
                return urls.filter { $0.pathExtension == "json" }
            }
            // Also try subdirectory API on the module bundle
            if let urls = moduleBundle.urls(forResourcesWithExtension: "json", subdirectory: "BuiltInSkins"),
               !urls.isEmpty {
                return urls
            }
        }

        // 2. Standard: bundled with subdirectory
        if let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "BuiltInSkins"),
           !urls.isEmpty {
            return urls
        }

        // 3. Flat bundle resources (no subdirectory — files copied to Resources root)
        if let resourceURL = Bundle.main.resourceURL {
            let builtInDir = resourceURL.appendingPathComponent("BuiltInSkins", isDirectory: true)
            if let urls = try? FileManager.default.contentsOfDirectory(at: builtInDir, includingPropertiesForKeys: nil),
               !urls.filter({ $0.pathExtension == "json" }).isEmpty {
                return urls.filter { $0.pathExtension == "json" }
            }
        }

        // 4. Next to executable (development builds, SPM)
        let executableURL = Bundle.main.executableURL?.deletingLastPathComponent()
        if let execDir = executableURL {
            let devDir = execDir.appendingPathComponent("BuiltInSkins", isDirectory: true)
            if let urls = try? FileManager.default.contentsOfDirectory(at: devDir, includingPropertiesForKeys: nil),
               !urls.filter({ $0.pathExtension == "json" }).isEmpty {
                return urls.filter { $0.pathExtension == "json" }
            }
        }

        return []
    }
}
