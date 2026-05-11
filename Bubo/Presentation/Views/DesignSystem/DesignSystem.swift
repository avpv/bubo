import SwiftUI

// MARK: - Design Tokens

/// Centralized design system for consistent spacing, sizing, typography, and colors.
///
/// The catalog is split across sibling files for navigation:
///
/// - `DesignSystem+Layout.swift`      — Spacing, Density, Hero, Popover,
///                                      Grid, SettingsWindow, EmptyState.
/// - `DesignSystem+Typography.swift`  — Type ramp + duration weight rules.
/// - `DesignSystem+Sizes.swift`       — Component sizes, Border, Opacity.
/// - `DesignSystem+Visual.swift`      — Shadows, Elevation, Physics,
///                                      Animation.
/// - `DesignSystem+Colors.swift`      — Semantic colors, Materials,
///                                      EventColorTag map, Urgency,
///                                      Countdown.
/// - `DesignSystem+Formatting.swift`  — SnoozeOption, Ordinal, Time,
///                                      Shared formatters.
enum DS {
}

// MARK: - Haptic Feedback (macOS Force Touch Trackpad)

/// HIG: Use appropriate haptic feedback patterns.
/// - `tap()`: Light feedback for standard button actions (generic pattern).
/// - `impact()`: Stronger feedback for significant state changes (levelChange).
/// - `alignment()`: For drag/alignment guides only (alignment pattern).
enum Haptics {
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic, performanceTime: .default
        )
    }

    static func impact() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .levelChange, performanceTime: .default
        )
    }

    static func alignment() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment, performanceTime: .default
        )
    }
}

// MARK: - Elevation Modifier

extension View {
    /// Apply a depth plane to the surface. The modifier is the single
    /// path through which `DS.Elevation`'s `radius` / `y` / `color`
    /// recipe reaches a SwiftUI `.shadow(...)` call — no per-call-site
    /// arithmetic, no skin field lookups in views.
    ///
    /// Always pass the active skin so per-skin shadow weight (the
    /// difference between e.g. Sierra and Midnight) carries through.
    /// Z0 is intentionally a no-op — it exists so every surface can
    /// declare its plane explicitly, even when it casts nothing.
    func elevation(_ level: DS.Elevation, skin: SkinDefinition) -> some View {
        self.shadow(
            color: level.color(skin: skin),
            radius: level.radius(skin: skin),
            y: level.y(skin: skin)
        )
    }
}

// MARK: - Motion-Aware Entrance Modifier

/// Replaces the repeated `appeared` + `onAppear` boilerplate across views.
/// Respects `accessibilityReduceMotion` — skips animation when enabled.
struct StaggeredEntrance: ViewModifier {
    var index: Int = 0
    var offsetY: CGFloat = DS.Spacing.sm

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : offsetY)
            .scaleEffect(appeared || reduceMotion ? 1.0 : 0.96)
            .onAppear {
                guard !reduceMotion else {
                    appeared = true
                    return
                }
                withAnimation(DS.Animation.staggered(index: index)) {
                    appeared = true
                }
            }
    }
}

extension View {
    /// Staggered entrance animation — respects Reduce Motion.
    func staggeredEntrance(index: Int = 0, offsetY: CGFloat = 8) -> some View {
        modifier(StaggeredEntrance(index: index, offsetY: offsetY))
    }
}

// MARK: - Scroll Transition Modifier

extension View {
    /// Applies a scroll-aware transition: items fade/scale as they enter/exit the visible area.
    func eventScrollTransition() -> some View {
        self.scrollTransition(.animated(DS.Animation.smoothSpring)) { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : DS.Opacity.tertiaryText)
                .scaleEffect(phase.isIdentity ? 1 : 0.94, anchor: .leading)
                .offset(x: phase.isIdentity ? 0 : phase.value * -DS.Spacing.sm)
        }
    }
}

// MARK: - Motion-Aware Animation Modifier

extension View {
    /// Wraps `.animation()` to become a no-op when Reduce Motion is active.
    func motionAwareAnimation<V: Equatable>(
        _ animation: Animation,
        value: V,
        reduceMotion: Bool
    ) -> some View {
        self.animation(
            reduceMotion ? .easeOut(duration: 0.01) : animation,
            value: value
        )
    }
}

// MARK: - Shared Section-Header Typography

extension Text {
    /// Single typographic voice for quiet, in-surface section headers
    /// (form section labels, day-group headers in the timeline, any
    /// subhead that guides the eye without shouting).
    ///
    /// Birman: one scale — `SectionLabel` and `DaySectionHeader` are the
    /// same typographic object, not two look-alikes. Centralising the
    /// style here guarantees they never drift apart.
    ///
    /// 2026 update: dropped uppercase + `tracking(0.4)`. Cap-height + letter
    /// spacing made these read like 1990s product chrome ("PROJECTS  ·
    /// TODAY"); a quiet semibold subhead in mixed case sits inside the
    /// content rather than shouting from above it. Step is `.footnote`
    /// (the smallest of the four-step ramp), not `.caption`, because
    /// `.caption` is no longer in the typographic ramp.
    func sectionHeaderStyle() -> some View {
        self.font(.footnote.weight(.semibold))
    }
}

// MARK: - Shared Section Label

/// Uniform section-label treatment used by form surfaces (AddEventView) and
/// any other view that needs a quiet, in-surface section divider.
///
/// Birman: within one surface, section titles are quiet subheads, not
/// headlines — they guide the eye without shouting. Same typographic voice
/// as `DaySectionHeader` via `sectionHeaderStyle()`.
struct SectionLabel: View {
    let text: String

    @Environment(\.activeSkin) private var skin

    var body: some View {
        Text(text)
            .sectionHeaderStyle()
            .foregroundStyle(skin.resolvedTextTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Adaptive Badge Background

/// A badge background that automatically adapts to High Contrast accessibility setting
/// and respects the active skin's badge style.
struct AdaptiveBadgeFill: ViewModifier {
    let tint: Color

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.activeSkin) private var skin

    func body(content: Content) -> some View {
        switch skin.badgeStyle {
        case .tinted:
            content.background(
                DS.Colors.badgeFill(tint, highContrast: contrast == .increased)
            )
        case .filled:
            content
                .foregroundStyle(DS.contrastingForeground(for: tint))
                .background(tint.opacity(contrast == .increased ? 0.9 : 0.75))
        case .outlined:
            content
                .background(Color.clear)
                .overlay(
                    Capsule()
                        .strokeBorder(tint.opacity(contrast == .increased ? 0.8 : 0.5), lineWidth: DS.Border.standard)
                )
        }
    }
}

extension View {
    func adaptiveBadgeFill(_ tint: Color) -> some View {
        modifier(AdaptiveBadgeFill(tint: tint))
    }
}

// MARK: - Navigation Home Environment

private struct NavigateHomeKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var navigateHome: (() -> Void)? {
        get { self[NavigateHomeKey.self] }
        set { self[NavigateHomeKey.self] = newValue }
    }
}

// MARK: - Reusable Header

/// Standard header bar used across popover views.
/// Material is determined by the active skin's `barMaterial` setting.
struct PopoverHeader: View {
    var title: String? = nil
    /// Optional second line rendered under `title`. When set, the title
    /// switches from a centered single-line layout to a left-aligned
    /// stacked pair (title + subtitle), matching the menu bar's
    /// «date over meta» rhythm. Other surfaces leave it nil and keep
    /// the existing centered behaviour bit-for-bit.
    var subtitle: String? = nil
    var showBack: Bool = false
    /// HIG: Back button should display the title of the previous screen.
    var backLabel: String = "Back"
    var onBack: (() -> Void)? = nil
    var trailing: AnyView? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.activeSkin) private var skin

    /// HIG: Navigation bar pattern — back button leading, title flexible in the
    /// middle, trailing items trailing. Uses a plain HStack with layout priorities
    /// instead of a ZStack so the title cannot collide with trailing indicators
    /// when both sides grow.
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.sm) {
                // Leading: back button OR owl icon (mutually exclusive — one symbol
                // at a time, not two).
                Group {
                    if showBack {
                        Button {
                            Haptics.tap()
                            onBack?()
                        } label: {
                            Label(backLabel, systemImage: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.escape, modifiers: [])
                    } else {
                        OwlIcon(size: DS.Size.headerIcon)
                            .foregroundStyle(skin.accentColor)
                    }
                }
                .layoutPriority(0)

                if let title, let subtitle {
                    // Two-line stacked layout — used by the menu bar
                    // «Today» header so the date and the day-meta line up
                    // on the leading edge instead of fighting for the
                    // visual centre.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(DS.Typography.headline(skin: skin))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(skin.resolvedTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(2)
                    .accessibilityElement(children: .combine)
                } else {
                    Spacer(minLength: DS.Spacing.xs)

                    // Title — flexible, truncates if space runs out.
                    if let title {
                        Text(title)
                            .font(DS.Typography.headline(skin: skin))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(2)
                    }

                    Spacer(minLength: DS.Spacing.xs)
                }

                // Trailing: optional status / action controls.
                if let trailing {
                    trailing
                        .layoutPriority(1)
                } else if showBack {
                    // Balance the back button so the title stays centered even
                    // without any trailing content.
                    Color.clear.frame(width: DS.Size.iconLarge, height: 1)
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .frame(minHeight: DS.Size.headerHeight)
            .skinBarBackground(skin)

            SkinSeparator()
        }
    }
}

// MARK: - Unified Action Button Style

enum ActionButtonRole {
    case primary
    case secondary
    case destructive
}

enum ActionButtonSize {
    case flexible // minWidth: 100, lg padding
    case compact  // padding: sm, xs
    case regular  // fixedSize, padding: md, sm
}

struct ActionButtonStyle: ButtonStyle {
    var role: ActionButtonRole = .primary
    var size: ActionButtonSize = .flexible

    @Environment(\.activeSkin) private var skin

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(skin.resolvedFontWeight)
            .font(.system(.body, design: skin.resolvedFontDesign))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, size == .compact ? 0 : verticalPadding)
            .frame(height: size == .compact ? DS.Size.controlHeight : nil)
            .frame(minWidth: size == .flexible ? 100 : nil)
            .fixedSize(horizontal: size == .regular, vertical: false)
            .contentShape(buttonContentShape)
            .background(backgroundView(isPressed: configuration.isPressed))
            .foregroundStyle(foregroundStyle)
            .clipShape(buttonClipShape)
            .overlay(buttonStrokeOverlay)
            .shadow(
                color: shadowColor(isPressed: configuration.isPressed),
                radius: configuration.isPressed ? skin.shadowRadius * 0.25 : (role == .primary ? skin.hoverShadowRadius : skin.shadowRadius),
                y: configuration.isPressed ? skin.shadowY * 0.25 : (role == .primary ? skin.hoverShadowY * 0.67 : skin.shadowY * 0.5)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(skin.resolvedMicroAnimation, value: configuration.isPressed)
    }

    private var skinAccent: Color {
        skin.isClassic ? DS.Colors.accent : skin.resolvedButtonAccentColor
    }

    // MARK: Shape

    private var buttonContentShape: AnyShape {
        switch skin.buttonShape {
        case .capsule:     AnyShape(Capsule())
        case .roundedRect: AnyShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius))
        case .rectangle:   AnyShape(Rectangle())
        }
    }

    private var buttonClipShape: AnyShape { buttonContentShape }

    @ViewBuilder
    private var buttonStrokeOverlay: some View {
        let opacity = role == .primary ? 0.3 : 0.06
        let width: CGFloat = role == .primary ? 1.0 : 0.5
        switch skin.buttonShape {
        case .capsule:
            Capsule()
                .strokeBorder(.white.opacity(opacity), lineWidth: width)
        case .roundedRect:
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius)
                .strokeBorder(.white.opacity(opacity), lineWidth: width)
        case .rectangle:
            Rectangle()
                .strokeBorder(.white.opacity(opacity), lineWidth: width)
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .flexible: return DS.Spacing.lg
        case .regular: return DS.Spacing.md
        case .compact: return DS.Spacing.sm
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .flexible, .regular: return DS.Spacing.sm
        case .compact: return DS.Spacing.xs
        }
    }

    @ViewBuilder
    private func backgroundView(isPressed: Bool) -> some View {
        switch role {
        case .primary:
            switch skin.buttonStyle {
            case .gradient:
                LinearGradient(
                    colors: isPressed
                        ? [skinAccent.opacity(0.75), skin.resolvedButtonSecondaryAccent.opacity(0.75)]
                        : [skinAccent, skin.resolvedButtonSecondaryAccent],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .glass:
                ZStack {
                    Rectangle().fill(skin.resolvedButtonMaterial)
                    skin.resolvedButtonTint.opacity(isPressed ? skin.buttonTintOpacity * 0.67 : skin.buttonTintOpacity)
                }
            case .solid:
                if isPressed {
                    skinAccent.opacity(0.8)
                } else {
                    skinAccent
                }
            }
        case .secondary:
            ZStack {
                Rectangle().fill(skin.resolvedButtonMaterial)
                if isPressed {
                    Color.primary.opacity(0.06)
                }
            }
        case .destructive:
            ZStack {
                Rectangle().fill(skin.resolvedButtonMaterial)
                if isPressed {
                    skin.resolvedDestructiveColor.opacity(0.08)
                }
            }
        }
    }

    private var foregroundStyle: Color {
        switch role {
        case .primary:
            // Explicit button color from skin takes priority
            if let custom = skin.buttonColor { return custom }
            if skin.buttonStyle == .glass { return skinAccent }
            // HIG: Ensure text contrast against accent background.
            // Use white on dark accents, primary label on light accents.
            return Self.contrastingForeground(for: skinAccent)
        case .secondary: return skin.resolvedTextPrimary
        case .destructive: return skin.resolvedDestructiveColor
        }
    }

    private static func contrastingForeground(for color: Color) -> Color {
        DS.contrastingForeground(for: color)
    }

    private func shadowColor(isPressed: Bool) -> Color {
        if isPressed { return .clear }
        switch role {
        case .primary: return skinAccent.opacity(0.35)
        case .secondary, .destructive: return skin.resolvedShadowColor
        }
    }
}

extension ButtonStyle where Self == ActionButtonStyle {
    static func action(role: ActionButtonRole = .primary, size: ActionButtonSize = .flexible) -> ActionButtonStyle {
        ActionButtonStyle(role: role, size: size)
    }
}

// MARK: - Icon Press Style
//
// `.buttonStyle(.plain)` strips macOS's default press feedback, which is fine
// for chromeless icon buttons (row checkboxes, hover-revealed chevrons) but
// loses the «press registered» physical cue. `IconPressStyle` is the same
// chromeless surface plus a single moment of feedback: the icon squishes 8%
// while the mouse is held, then springs back. No background, no shadow —
// purpose-built for naked-glyph buttons that already live inside a row of
// their own visual treatment.
//
// Pair with `Haptics.tap()` in the action closure for a coherent
// visual + tactile «click» — see `BacklogTaskRow.checkbox`.
struct IconPressStyle: ButtonStyle {
    /// How far down the icon goes while held. Default uses the shared
    /// `DS.Physics.pressedIconScale` token so all chromeless buttons in
    /// the app squish the same amount.
    var pressedScale: CGFloat = DS.Physics.pressedIconScale

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Asymmetric easing — physical fingers accelerate INTO a press
    /// (`.easeIn`) and the spring decelerates OUT (`.easeOut`). A single
    /// `.easeOut` for both directions reads «mechanical»; the asymmetric
    /// pair feels «soft». Evaluation time: SwiftUI sees the new value of
    /// `configuration.isPressed`, so true-direction = press (easeIn),
    /// false-direction = release (easeOut).
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1.0)
            .animation(
                reduceMotion
                    ? nil
                    : (configuration.isPressed
                        ? .easeIn(duration: 0.10)
                        : .easeOut(duration: 0.18)),
                value: configuration.isPressed
            )
    }
}

extension ButtonStyle where Self == IconPressStyle {
    /// Chromeless icon button with a press-scale feedback. Replaces
    /// `.plain` on naked-glyph triggers (checkbox, hover chevrons) where the
    /// click should feel physical without growing chrome.
    static var iconPress: IconPressStyle { IconPressStyle() }
}
