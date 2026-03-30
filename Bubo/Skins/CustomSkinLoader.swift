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

    func toSkinDefinition(skinFileURL: URL? = nil) -> SkinDefinition {
        // HIG: Validate accent color contrast — warn if luminance is too high
        // for white button text (WCAG 2.1 AA requires 4.5:1 contrast ratio)
        let accentLuminance = 0.2126 * accentColor.red + 0.7152 * accentColor.green + 0.0722 * accentColor.blue
        if accentLuminance > 0.55 {
            print("[Bubo] Warning: Skin '\(displayName)' accent color has high luminance (\(String(format: "%.2f", accentLuminance))). Button text may have insufficient contrast per Apple HIG.")
        }

        return SkinDefinition(
            id: "custom_\(id)",
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

struct JSONColor: Codable {
    let red: Double
    let green: Double
    let blue: Double
    var opacity: Double?

    func toColor() -> Color {
        Color(red: red, green: green, blue: blue).opacity(opacity ?? 1.0)
    }
}

struct JSONGradient: Codable {
    let colors: [JSONColor]
    let style: String  // "linear" or "radial"
    // Linear
    var startPoint: String?
    var endPoint: String?
    // Radial
    var center: String?
    var startRadius: CGFloat?
    var endRadius: CGFloat?

    func toSkinGradient() -> SkinGradient {
        let swiftColors = colors.map { $0.toColor() }
        let gradientStyle: SkinGradient.Style
        if style.lowercased() == "radial" {
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
