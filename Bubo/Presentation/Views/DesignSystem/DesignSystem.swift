import SwiftUI
import BuboDomain

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
    /// Optional colour override for hosts that carry a state signal in
    /// the label — `DaySectionView` tints the «Today» eyebrow with the
    /// skin accent. nil = the default tertiary section voice.
    var tint: Color? = nil

    @Environment(\.activeSkin) private var skin

    var body: some View {
        Text(text)
            .sectionHeaderStyle()
            .foregroundStyle(tint ?? skin.resolvedTextTertiary)
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
    /// Whether the back button claims the Escape key. Pushed screens keep
    /// the default; modal *forms* pass `false` because their footer Cancel
    /// already owns `.cancelAction` (also Escape) — two live bindings on
    /// one screen made the dismissal path ambiguous, and only the Cancel
    /// path is draft-aware.
    var backBindsEscape: Bool = true
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
                        let back = Button {
                            Haptics.tap()
                            onBack?()
                        } label: {
                            Label(backLabel, systemImage: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        if backBindsEscape {
                            back.keyboardShortcut(.escape, modifiers: [])
                        } else {
                            back
                        }
                    } else {
                        OwlIcon(size: DS.Size.headerIcon)
                            .foregroundStyle(skin.accentColor)
                    }
                }
                .layoutPriority(0)

                if let title, let subtitle {
                    // Two-line stacked layout — used by the menu bar
                    // «Today» header. Mirrors the prototype's
                    // `.topbar .day` (700 15pt rounded) over
                    // `.topbar .meta` (500 11pt) with 1pt baseline gap.
                    // Text styles, not pinned point sizes — the ramp's
                    // headline (title3 ≈ 15pt) / subhead (footnote) pair
                    // keeps the header scaling with the system (HIG
                    // typography; PRINCIPLES §8).
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(DS.Typography.headline(skin: skin, weight: .bold))
                            .foregroundStyle(skin.resolvedTextPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(subtitle)
                            .font(DS.Typography.subhead(skin: skin))
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
    /// Accent-tinted quiet button — accent text on a translucent accent
    /// fill, no shadow. For per-item actions that deserve the accent hue
    /// without competing with the screen's one primary CTA (DESIGN_REVIEW
    /// R1: the per-row Join wore the same primary treatment as Add, so
    /// nothing read as primary). Mirrors macOS's «tinted» button grammar.
    case tinted
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
        // No «shine» bevel on filled buttons (DESIGN_REVIEW R2: the white
        // gloss stroke is a skeuomorphic tell — modern macOS primaries are
        // flat). Material-backed roles keep a 0.5pt hairline so they read
        // as buttons on any canvas.
        if role == .secondary || role == .destructive {
            switch skin.buttonShape {
            case .capsule:
                Capsule()
                    .strokeBorder(.white.opacity(0.06), lineWidth: DS.Border.thin)
            case .roundedRect:
                RoundedRectangle(cornerRadius: DS.Size.cornerRadius)
                    .strokeBorder(.white.opacity(0.06), lineWidth: DS.Border.thin)
            case .rectangle:
                Rectangle()
                    .strokeBorder(.white.opacity(0.06), lineWidth: DS.Border.thin)
            }
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
            case .glass:
                ZStack {
                    Rectangle().fill(skin.resolvedButtonMaterial)
                    skin.resolvedButtonTint.opacity(isPressed ? skin.buttonTintOpacity * 0.67 : skin.buttonTintOpacity)
                }
            case .solid, .gradient:
                // `.gradient` renders flat too (DESIGN_REVIEW R2): the
                // topLeading→bottomTrailing accent gradient was the
                // single biggest «dated» tell — modern macOS primaries
                // are a flat solid accent fill. The case stays parseable
                // so existing skin JSONs keep loading.
                if isPressed {
                    skinAccent.opacity(0.8)
                } else {
                    skinAccent
                }
            }
        case .tinted:
            skinAccent.opacity(
                isPressed ? DS.Opacity.strongFill : DS.Opacity.selectedChipFill
            )
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
        case .tinted: return skinAccent
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
        // Neutral shadows only (DESIGN_REVIEW R2): the primary used to
        // cast an accent-coloured glow — neon halos read as decoration,
        // native elevation is a low-alpha neutral drop.
        case .primary, .secondary, .destructive: return skin.resolvedShadowColor
        case .tinted: return .clear
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

// MARK: - Header Control Style
//
// Quiet hover-pill for verbs that live ON chrome bars — the popover
// header's trailing cluster (Filter, ‹ Today ›). At rest the control is
// naked text or glyph: chrome stays banded and controls don't box
// themselves (PRINCIPLES §11). On hover a soft capsule fill fades in
// (the Notes/Calendar toolbar idiom), so the element declares «I am a
// button» exactly when the pointer asks — the affordance the previous
// bare `.borderless` glyphs never gave. The press dips by the shared
// `pressedIconScale`, so bar verbs and row glyphs speak one physical
// vocabulary. The capsule padding doubles as hit-target slack around
// the small glyphs (HIG target sizes).
struct HeaderControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HeaderControlLabel(configuration: configuration)
    }

    /// Inner view so the style can own hover state (`ButtonStyle`
    /// itself has no storage).
    private struct HeaderControlLabel: View {
        let configuration: ButtonStyleConfiguration

        @Environment(\.activeSkin) private var skin
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xs)
                .background(
                    Capsule()
                        .fill(skin.resolvedHoverFill)
                        .opacity(isHovered && isEnabled ? 1 : 0)
                )
                .contentShape(Capsule())
                // Custom styles opt out of `.borderless`'s automatic
                // disabled dimming — drawn by hand so the day-nav
                // chevrons still fade at the timeline's edges.
                .opacity(isEnabled ? 1.0 : 0.35)
                .scaleEffect(
                    configuration.isPressed && !reduceMotion
                        ? DS.Physics.pressedIconScale
                        : 1.0
                )
                .onHover { hovering in
                    // Soft colour swap; the default hard cut feels
                    // twitchy on macOS (same rationale as
                    // ContextualActionRow).
                    withAnimation(DS.Animation.quick) { isHovered = hovering }
                }
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
}

extension ButtonStyle where Self == HeaderControlStyle {
    /// Hover-pill for header-bar verbs (Filter, day-nav cluster): naked
    /// at rest, capsule hover fill, `IconPressStyle`-matched press dip.
    static var headerControl: HeaderControlStyle { HeaderControlStyle() }
}
