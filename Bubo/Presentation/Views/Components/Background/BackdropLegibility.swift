import Foundation
import SwiftUI

// MARK: - Backdrop Legibility
//
// Skins, wallpapers and the design system are authored on three separate
// surfaces, but the user reads them as ONE canvas — and the canvas is the
// first impression. Before this contract existed the three could combine
// into an unreadable window: a light wallpaper under system Dark Mode kept
// white `labelColor` text (white-on-paper), and a saturated blue wallpaper
// swallowed the skin's blue accent (blue-on-blue). This file is the single
// place where the three surfaces agree on legibility:
//
//   1. Every wallpaper knows the luminance of the canvas it paints
//      (`averageCanvasColor` / `contentColorScheme`). Foreground polarity
//      follows the *canvas*, not the system appearance — a light wallpaper
//      gets dark labels even when macOS is in Dark Mode.
//   2. Mid-luminance canvases (sage, marina) get a faint `legibilityScrim`
//      that pushes them toward the chosen pole so labels clear contrast.
//   3. The skin's canvas-facing accent is nudged toward the readable pole
//      when the wallpaper would swallow it (`adaptedToBackdrop`) — blue
//      countdowns stay readable on a blue wallpaper. Button surfaces keep
//      the authored accent: their text contrasts against the button fill,
//      not the canvas.
//
// The polarity is forced at each canvas root (`MenuBarView`, the pinned
// timer panel) via `backdropColorScheme(_:)` so `labelColor`, materials
// and separators all flip together. `nil` means «no wallpaper owns the
// canvas — follow the system appearance», the pre-wallpaper behaviour.

// MARK: - Luminance & contrast primitives

extension DS {
    /// Perceived luminance of a color in sRGB (0 = black … 1 = white),
    /// gamma-naive — the same weighting `contrastingForeground(for:)` has
    /// always used. Drives *polarity* decisions (is this canvas light or
    /// dark?); contrast *ratios* use `relativeLuminance(of:)` below.
    static func perceivedLuminance(of color: Color) -> Double {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return 0.2126 * nsColor.redComponent
            + 0.7152 * nsColor.greenComponent
            + 0.0722 * nsColor.blueComponent
    }

    /// WCAG relative luminance — linearized sRGB, the photometric scale
    /// contrast ratios are defined on. The gamma-naive
    /// `perceivedLuminance` overestimates mid-tones (a sky blue reads
    /// «half as bright as white» when photometrically it's a quarter),
    /// which over-triggers accent nudging; ratios must use this one.
    static func relativeLuminance(of color: Color) -> Double {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(nsColor.redComponent)
            + 0.7152 * linear(nsColor.greenComponent)
            + 0.0722 * linear(nsColor.blueComponent)
    }

    /// WCAG contrast ratio between two colors (1 … 21).
    static func contrastRatio(_ a: Color, _ b: Color) -> Double {
        let la = relativeLuminance(of: a)
        let lb = relativeLuminance(of: b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Minimum contrast for accent-colored text over the canvas — WCAG's
    /// 3:1 large-text / UI-component floor. Curated accents on clean light
    /// or dark canvases pass untouched; only genuinely swallowed accents
    /// get nudged.
    static let accentContrastFloor: Double = 3.0

    /// Nudges `accent` toward the readable pole (white on dark canvases,
    /// black on light ones) until it clears the contrast floor over
    /// `canvas`. The blend walks in 10% steps and stops at the first step
    /// that reads, so hue is preserved as far as possible.
    ///
    /// The floor adapts to the canvas: on a mid-dark canvas even pure
    /// white barely clears 3:1, so demanding the full floor would bleach
    /// every accent to white. Capping the requirement at 80% of what the
    /// pole itself achieves keeps the accent one clear step *below*
    /// primary labels — readable, but still an accent.
    static func readableAccent(_ accent: Color, over canvas: Color) -> Color {
        let canvasIsLight = perceivedLuminance(of: canvas) > 0.55
        let pole: NSColor = canvasIsLight ? .black : .white
        let poleContrast = contrastRatio(Color(nsColor: pole), canvas)
        let floor = min(accentContrastFloor, poleContrast * 0.8)
        guard contrastRatio(accent, canvas) < floor else { return accent }
        let base = NSColor(accent).usingColorSpace(.sRGB) ?? NSColor(accent)
        var best = accent
        for step in stride(from: 0.1, through: 0.9, by: 0.1) {
            guard let blended = base.blended(withFraction: step, of: pole) else { break }
            best = Color(nsColor: blended)
            if contrastRatio(best, canvas) >= floor { return best }
        }
        return best
    }
}

// MARK: - What canvas does a wallpaper paint?

extension WallpaperDefinition {
    /// The colors that dominate this wallpaper's canvas, or `nil` when the
    /// wallpaper doesn't own the canvas: «none», and «auto» paired with
    /// Classic — there the native window material *is* the canvas.
    func canvasColors(for skin: SkinDefinition) -> [Color]? {
        if id == "none" { return nil }
        if id == "auto" {
            guard !skin.isClassic else { return nil }
            let colors = skin.previewColors
            return colors.isEmpty ? [skin.accentColor] : colors
        }
        switch category {
        case .solidColor:
            return solidColor.map { [$0] }
        case .gradient:
            return gradientColors.isEmpty ? nil : gradientColors
        case .pattern:
            // Foreground strokes sit at ~0.04 alpha — the background IS
            // the canvas.
            return patternColors.map { [$0.background] }
        case .live:
            // Every live canvas is authored over a near-black base (see
            // the `LiveXxxView` base fills) — one dark stand-in instead
            // of twelve duplicated constants.
            return [Color(red: 0.04, green: 0.05, blue: 0.09)]
        }
    }

    /// Average canvas color — the one value all legibility rules read.
    func averageCanvasColor(for skin: SkinDefinition) -> Color? {
        guard let colors = canvasColors(for: skin), !colors.isEmpty else { return nil }
        var r = 0.0, g = 0.0, b = 0.0
        for color in colors {
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
            r += ns.redComponent
            g += ns.greenComponent
            b += ns.blueComponent
        }
        let n = Double(colors.count)
        return Color(red: r / n, green: g / n, blue: b / n)
    }

    /// Foreground polarity for content over this wallpaper. `.light` on
    /// bright canvases (dark labels), `.dark` on deep ones (light labels).
    /// `nil` = no forced polarity — follow the system appearance.
    func contentColorScheme(for skin: SkinDefinition) -> ColorScheme? {
        guard let canvas = averageCanvasColor(for: skin) else { return nil }
        return DS.perceivedLuminance(of: canvas) > 0.55 ? .light : .dark
    }

    /// The canvas as the eye actually sees it — the average color with the
    /// legibility scrim composited on top. Accent adaptation reads this so
    /// it doesn't over-correct for a wash the scrim already applied.
    func effectiveCanvasColor(for skin: SkinDefinition) -> Color? {
        guard let canvas = averageCanvasColor(for: skin) else { return nil }
        guard let scrim = legibilityScrim(for: skin) else { return canvas }
        let base = NSColor(canvas).usingColorSpace(.sRGB) ?? NSColor(canvas)
        guard let composited = base.blended(withFraction: scrim.opacity, of: NSColor(scrim.color)) else {
            return canvas
        }
        return Color(nsColor: composited)
    }

    /// A faint neutral scrim that pushes a mid-luminance canvas toward its
    /// chosen pole so labels clear contrast — sage green darkens a touch
    /// under light text, marina blue lightens a touch under dark text.
    /// Returns `nil` when the canvas is already clearly light or dark;
    /// authored wallpaper colors stay untouched in the common case.
    func legibilityScrim(for skin: SkinDefinition) -> (color: Color, opacity: Double)? {
        guard let canvas = averageCanvasColor(for: skin) else { return nil }
        let lum = DS.perceivedLuminance(of: canvas)
        if lum > 0.55 {
            let opacity = min(0.28, max(0, (0.78 - lum) * 0.75))
            return opacity > 0.01 ? (.white, opacity) : nil
        } else {
            let opacity = min(0.28, max(0, (lum - 0.32) * 0.75))
            return opacity > 0.01 ? (.black, opacity) : nil
        }
    }
}

// MARK: - Skin accent adaptation

extension SkinDefinition {
    /// A copy of the skin whose *canvas-facing* accent is nudged toward
    /// the readable pole when the active wallpaper would swallow it —
    /// «Today», countdowns and free-slot verbs stay readable on a
    /// same-hue wallpaper. Button surfaces freeze the authored resolution
    /// so primary CTAs keep the skin's brand color: their text contrasts
    /// against the button fill, not the canvas.
    func adaptedToBackdrop(_ wallpaper: WallpaperDefinition) -> SkinDefinition {
        guard let canvas = wallpaper.effectiveCanvasColor(for: self) else { return self }
        let readable = DS.readableAccent(accentColor, over: canvas)
        guard readable != accentColor else { return self }
        return SkinDefinition(
            id: id,
            displayName: displayName,
            author: author,
            accentColor: readable,
            prefersDarkTint: prefersDarkTint,
            darkMoodMode: darkMoodMode,
            backgroundGradient: backgroundGradient,
            previewColors: previewColors,
            secondaryAccent: secondaryAccent,
            barTint: barTint,
            barTintOpacity: barTintOpacity,
            platterTint: platterTint,
            platterTintOpacity: platterTintOpacity,
            buttonStyle: buttonStyle,
            buttonShape: buttonShape,
            buttonColor: buttonColor,
            buttonAccentColor: resolvedButtonAccentColor,
            buttonSecondaryAccent: resolvedButtonSecondaryAccent,
            buttonTint: resolvedButtonTint,
            fontWeight: fontWeight,
            fontDesign: fontDesign,
            badgeStyle: badgeStyle,
            separatorStyle: separatorStyle
        )
    }
}

// MARK: - Forced polarity modifier

/// Forces the content hierarchy's color scheme to the wallpaper's polarity
/// so `labelColor`, materials and separators flip together. `nil` keeps the
/// system appearance — the identity when no wallpaper owns the canvas.
private struct BackdropColorSchemeModifier: ViewModifier {
    let scheme: ColorScheme?

    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, scheme ?? systemScheme)
    }
}

extension View {
    /// Applies the wallpaper-derived foreground polarity to this hierarchy.
    /// Pass `wallpaper.contentColorScheme(for: skin)`; `nil` follows the
    /// system appearance unchanged.
    func backdropColorScheme(_ scheme: ColorScheme?) -> some View {
        modifier(BackdropColorSchemeModifier(scheme: scheme))
    }
}
