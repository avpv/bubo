import Foundation
import SwiftUI

// MARK: - Skin JSON Format

/// JSON-serializable representation of a Bubo skin.
///
/// Both built-in and custom skins use the same `.buboskin` JSON format.
/// Colors are strings: hex (`"#0070FA"`), named (`"accentColor"`),
/// named with opacity (`"accentColor:0.5"`), or keyword (`"clear"`).
///
/// Example `.buboskin` file:
/// ```json
/// {
///   "id": "my_cool_skin",
///   "displayName": "My Cool Skin",
///   "author": "@username",
///   "accentColor": "#00E600",
///   "surfaceTint": "#002600",
///   "surfaceTintOpacity": 0.35,
///   "backgroundGradient": {
///     "colors": ["#002E0080", "#001A0D4C", "clear"],
///     "style": "linear",
///     "startPoint": "topLeading",
///     "endPoint": "bottomTrailing"
///   },
///   "previewColors": ["#00B200", "#1A3319"],
///   "prefersDarkTint": true,
///   "buttonStyle": "gradient"
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

    // MARK: Layout & Depth (HIG 2026)

    /// Corner radius for platters and popovers. Defaults to 12.
    let cornerRadius: CGFloat?

    /// Ambient shadow opacity for depth. Defaults to 0.06.
    let shadowOpacity: Double?

    /// Ambient shadow blur radius. Defaults to 8.
    let shadowRadius: CGFloat?

    /// Ambient shadow vertical offset. Defaults to 4.
    let shadowY: CGFloat?

    /// Opacity of intrinsic 1px inner border on platters (glass edge highlight). Defaults to 0.
    let platterBorderOpacity: Double?

    // MARK: Advanced Interactions & Text (HIG 2026+)

    let textPrimary: JSONColor?
    let textSecondary: JSONColor?
    let textTertiary: JSONColor?
    
    /// Animation style: "bouncy", "smooth", "snappy". Defaults to "smooth".
    let animationStyle: String?

    let hoverShadowOpacity: Double?
    let hoverShadowRadius: CGFloat?
    let hoverShadowY: CGFloat?
    let hoverFillOpacity: Double?

    // MARK: Typography & Symbols (HIG 2026)

    /// Font design: "default", "rounded". Defaults to "rounded".
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
            cornerRadius: cornerRadius ?? 12,
            shadowOpacity: shadowOpacity ?? 0.06,
            shadowRadius: shadowRadius ?? 8,
            shadowY: shadowY ?? 4,
            platterBorderOpacity: platterBorderOpacity ?? 0,
            textPrimary: textPrimary?.toColor(),
            textSecondary: textSecondary?.toColor(),
            textTertiary: textTertiary?.toColor(),
            animationStyle: resolvedAnimationStyle,
            hoverShadowOpacity: hoverShadowOpacity ?? 0.12,
            hoverShadowRadius: hoverShadowRadius ?? 12,
            hoverShadowY: hoverShadowY ?? 6,
            hoverFillOpacity: hoverFillOpacity ?? 0.06,
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

    private var resolvedAnimationStyle: SkinAnimationStyle {
        guard let value = animationStyle?.lowercased() else { return .smooth }
        return SkinAnimationStyle(rawValue: value) ?? .smooth
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
               !urls.filter({ $0.pathExtension == "buboskin" }).isEmpty {
                return urls.filter { $0.pathExtension == "buboskin" }
            }
            // Also try subdirectory API on the module bundle
            if let urls = moduleBundle.urls(forResourcesWithExtension: "buboskin", subdirectory: "BuiltInSkins"),
               !urls.isEmpty {
                return urls
            }
        }

        // 2. Standard: bundled with subdirectory
        if let urls = Bundle.main.urls(forResourcesWithExtension: "buboskin", subdirectory: "BuiltInSkins"),
           !urls.isEmpty {
            return urls
        }

        // 3. Flat bundle resources (no subdirectory — files copied to Resources root)
        if let resourceURL = Bundle.main.resourceURL {
            let builtInDir = resourceURL.appendingPathComponent("BuiltInSkins", isDirectory: true)
            if let urls = try? FileManager.default.contentsOfDirectory(at: builtInDir, includingPropertiesForKeys: nil),
               !urls.filter({ $0.pathExtension == "buboskin" }).isEmpty {
                return urls.filter { $0.pathExtension == "buboskin" }
            }
        }

        // 4. Next to executable (development builds, SPM)
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
