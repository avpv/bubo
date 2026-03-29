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

    /// Background image settings. The actual image file should be placed
    /// next to the `.buboskin` file with the filename specified here.
    let backgroundImage: JSONBackgroundImage?

    func toSkinDefinition(skinFileURL: URL? = nil) -> SkinDefinition {
        var bgImage: SkinBackgroundImage? = nil
        if let imgSpec = backgroundImage, let skinURL = skinFileURL {
            let imageURL = skinURL.deletingLastPathComponent()
                .appendingPathComponent(imgSpec.filename)
            if FileManager.default.fileExists(atPath: imageURL.path) {
                bgImage = SkinBackgroundImage(
                    imageURL: imageURL,
                    opacity: imgSpec.opacity ?? 0.3,
                    fillMode: imgSpec.resolvedFillMode,
                    blurRadius: imgSpec.blur ?? 0
                )
            }
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
            backgroundImage: bgImage
        )
    }

    private var resolvedButtonStyle: SkinButtonStyle {
        switch buttonStyle?.lowercased() {
        case "solid": .solid
        case "glass": .glass
        default: .gradient
        }
    }
}

struct JSONBackgroundImage: Codable {
    /// Image filename (e.g. "background.jpg"). Must be in the same folder as the .buboskin file.
    let filename: String
    /// Opacity 0.0–1.0. Default 0.3 to keep text readable.
    var opacity: Double?
    /// Fill mode: "fill" (crop to fill) or "fit" (letterbox). Default "fill".
    var fillMode: String?
    /// Blur radius. Default 0.
    var blur: Double?

    var resolvedFillMode: SkinBackgroundImage.FillMode {
        switch fillMode?.lowercased() {
        case "fit": .fit
        default: .fill
        }
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
    /// If the skin specifies a `backgroundImage`, the image file is copied too.
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

            // If skin references a background image, copy it alongside
            if let data = try? Data(contentsOf: sourceURL),
               let json = try? JSONDecoder().decode(CustomSkinJSON.self, from: data),
               let bgImage = json.backgroundImage {
                let imageSource = sourceURL.deletingLastPathComponent()
                    .appendingPathComponent(bgImage.filename)
                let imageDest = skinsDirectory.appendingPathComponent(bgImage.filename)
                try? fileManager.removeItem(at: imageDest)
                try? fileManager.copyItem(at: imageSource, to: imageDest)
            }
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

    /// Remove a custom skin and its associated background image by ID.
    func removeSkin(id: String) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: skinsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.pathExtension == "buboskin" {
            if let data = try? Data(contentsOf: file),
               let json = try? JSONDecoder().decode(CustomSkinJSON.self, from: data),
               "custom_\(json.id)" == id {
                // Remove associated background image
                if let bgImage = json.backgroundImage {
                    let imageURL = skinsDirectory.appendingPathComponent(bgImage.filename)
                    try? fileManager.removeItem(at: imageURL)
                }
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
