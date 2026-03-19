import SwiftUI

// MARK: - Design Tokens

/// Centralized design system for consistent spacing, sizing, typography, and colors.
enum DS {

    // MARK: Spacing Scale (4-point grid)

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let pillVertical: CGFloat = 6
        static let pillHorizontal: CGFloat = 10
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: Popover Dimensions

    enum Popover {
        static let width: CGFloat = 340
        static let listMaxHeight: CGFloat = 360
        static let detailMaxHeight: CGFloat = 300
        static let formMaxHeight: CGFloat = 480
        static let detailMinHeight: CGFloat = 200
    }

    // MARK: Settings Window

    enum Settings {
        static let width: CGFloat = 480
        static let minHeight: CGFloat = 400
        static let idealHeight: CGFloat = 460
    }

    // MARK: Empty State

    enum EmptyState {
        static let iconSize: CGFloat = 42
        static let spacing: CGFloat = 12
    }

    // MARK: Typography

    enum Typography {
        static let bodyLineSpacing: CGFloat = 3
    }

    // MARK: Component Sizes

    enum Size {
        static let accentBarWidth: CGFloat = 4
        static let accentBarHeight: CGFloat = 28
        static let eventRowMinHeight: CGFloat = 36
        static let actionFooterHeight: CGFloat = 48
        static let timeColumnWidth: CGFloat = 50
        static let datePillWidth: CGFloat = 54
        static let timePillWidth: CGFloat = 52
        static let controlHeight: CGFloat = 28
        static let focusRingWidth: CGFloat = 2
        static let iconSmall: CGFloat = 12
        static let iconMedium: CGFloat = 14
        static let iconLarge: CGFloat = 16
        static let headerIcon: CGFloat = 20
        static let cornerRadius: CGFloat = 12
        static let badgeCornerRadius: CGFloat = 20
        static let syncIndicatorSize: CGFloat = 14
        static let todayDotSize: CGFloat = 6
    }
    
    // MARK: Shadows
    
    enum Shadows {
        static let ambientColor = Color.black.opacity(0.06)
        static let ambientRadius: CGFloat = 8
        static let ambientY: CGFloat = 4
        
        static let hoverColor = Color.black.opacity(0.12)
        static let hoverRadius: CGFloat = 12
        static let hoverY: CGFloat = 6
        
        static let pillRadius: CGFloat = 1
        static let pillY: CGFloat = 1
    }

    // MARK: Animation

    enum Animation {
        static let quick: SwiftUI.Animation = .easeInOut(duration: 0.15)
        static let standard: SwiftUI.Animation = .easeInOut(duration: 0.2)
        static let entrance: SwiftUI.Animation = .easeOut(duration: 0.3)

        // Spring-based animations for natural, modern feel (macOS 2026 standard)
        static let microInteraction: SwiftUI.Animation = .spring(duration: 0.3, bounce: 0.15)
        static let gentleBounce: SwiftUI.Animation = .spring(duration: 0.35, bounce: 0.25)
        static let smoothSpring: SwiftUI.Animation = .spring(duration: 0.4, bounce: 0.2)
        static let staggerBase: SwiftUI.Animation = .spring(duration: 0.4, bounce: 0.2)

        /// Staggered entrance animation for list items.
        static func staggered(index: Int) -> SwiftUI.Animation {
            staggerBase.delay(Double(index) * 0.04)
        }

        /// Returns `.identity` (no animation) when Reduce Motion is on,
        /// otherwise returns the provided animation.
        static func motionAware(
            _ animation: SwiftUI.Animation,
            reduceMotion: Bool
        ) -> SwiftUI.Animation {
            reduceMotion ? .easeOut(duration: 0.01) : animation
        }
    }

    // MARK: Semantic Colors (adaptive, respects appearance & accessibility)

    enum Colors {
        // Surface colors — adapt to light/dark and vibrancy
        static let surfacePrimary = Color(nsColor: .windowBackgroundColor)
        static let surfaceSecondary = Color(nsColor: .controlBackgroundColor)
        static let surfaceElevated = Color(nsColor: .underPageBackgroundColor)

        // Text colors — semantic hierarchy
        static let textPrimary = Color(nsColor: .labelColor)
        static let textSecondary = Color(nsColor: .secondaryLabelColor)
        static let textTertiary = Color(nsColor: .tertiaryLabelColor)
        static let textQuaternary = Color(nsColor: .quaternaryLabelColor)

        // Accent & interactive
        static let accent = Color.accentColor
        static let accentSubtle = Color.accentColor.opacity(0.12)

        // Semantic status
        static let success = Color(nsColor: .systemGreen)
        static let warning = Color(nsColor: .systemOrange)
        static let error = Color(nsColor: .systemRed)
        static let info = Color(nsColor: .systemBlue)

        // Separator & borders
        static let separator = Color(nsColor: .separatorColor)
        static let border = Color(nsColor: .separatorColor).opacity(0.5)

        // Hover & selection states
        static let hoverFill = Color(nsColor: .labelColor).opacity(0.06)
        static let selectedFill = Color.accentColor.opacity(0.1)

        /// Badge/tag backgrounds — adaptive to accessibility contrast setting.
        static func badgeFill(_ tint: Color, highContrast: Bool = false) -> Color {
            tint.opacity(highContrast ? 0.22 : 0.12)
        }

        // Calendar-specific
        static let calendarLabel = Color(nsColor: .systemBlue)
    }

    // MARK: Materials (vibrancy)

    enum Materials {
        static let toast: Material = .regularMaterial
        static let overlay: Material = .ultraThinMaterial
        static let hud: Material = .thickMaterial
        /// Header/footer bars — use thickMaterial for richer vibrancy than `.bar`
        static let headerBar: Material = .thickMaterial
        static let platter: Material = .regularMaterial
    }

    // MARK: Urgency Colors

    static func urgencyColor(minutesUntil: Int) -> Color {
        if minutesUntil <= 5 { return Colors.error }
        if minutesUntil <= 15 { return Colors.warning }
        return Colors.success
    }

    // MARK: Countdown Colors

    static func countdownColor(secondsRemaining: Int) -> Color {
        if secondsRemaining <= 120 { return Colors.error }
        if secondsRemaining <= 300 { return Colors.warning }
        return .white
    }

    // MARK: Snooze Options

    struct SnoozeOption: Identifiable {
        let id: Int
        let minutes: Int
        let label: String

        init(_ minutes: Int) {
            self.id = minutes
            self.minutes = minutes
            self.label = DS.formatMinutes(minutes)
        }
    }

    static let snoozeOptions: [SnoozeOption] = [
        SnoozeOption(5),
        SnoozeOption(10),
        SnoozeOption(15),
    ]

    // MARK: Ordinal Formatting

    static func formatOrdinal(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: Time Formatting

    static func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m == 0 ? "\(h) h" : "\(h) h \(m) min"
        }
        return "\(minutes) min"
    }

    // MARK: Shared Formatters

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let daySectionFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()
}

// MARK: - Haptic Feedback (macOS Force Touch Trackpad)

enum Haptics {
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment, performanceTime: .default
        )
    }

    static func impact() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .levelChange, performanceTime: .default
        )
    }

    static func generic() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic, performanceTime: .default
        )
    }
}

// MARK: - Motion-Aware Entrance Modifier

/// Replaces the repeated `appeared` + `onAppear` boilerplate across views.
/// Respects `accessibilityReduceMotion` — skips animation when enabled.
struct StaggeredEntrance: ViewModifier {
    var index: Int = 0
    var offsetY: CGFloat = 8

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : offsetY)
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
        self.scrollTransition(.animated(.spring(duration: 0.4, bounce: 0.2))) { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.4)
                .scaleEffect(phase.isIdentity ? 1 : 0.94, anchor: .leading)
                .offset(x: phase.isIdentity ? 0 : phase.value * -8)
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

// MARK: - Adaptive Badge Background

/// A badge background that automatically adapts to High Contrast accessibility setting.
struct AdaptiveBadgeFill: ViewModifier {
    let tint: Color

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background(
            DS.Colors.badgeFill(tint, highContrast: contrast == .increased)
        )
    }
}

extension View {
    func adaptiveBadgeFill(_ tint: Color) -> some View {
        modifier(AdaptiveBadgeFill(tint: tint))
    }
}

// MARK: - Reusable Header

/// Standard header bar used across popover views.
/// Uses `.thickMaterial` for rich vibrancy instead of plain `.bar`.
struct PopoverHeader: View {
    var title: String? = nil
    var showBack: Bool = false
    var onBack: (() -> Void)? = nil
    var trailing: AnyView? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.xs) {
                if showBack {
                    Button {
                        Haptics.tap()
                        onBack?()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .keyboardShortcut(.escape, modifiers: [])
                }

                if !showBack {
                    OwlIcon(size: DS.Size.headerIcon)
                }

                if let title = title, !showBack {
                    Text(title)
                        .font(.headline)
                }

                Spacer()

                if let title = title, showBack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                }

                if showBack {
                    OwlIcon(size: DS.Size.headerIcon)
                } else if let trailing = trailing {
                    trailing
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.md)
            .background(DS.Materials.headerBar)

            Divider()
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, size == .compact ? 0 : verticalPadding)
            .frame(height: size == .compact ? DS.Size.controlHeight : nil)
            .frame(minWidth: size == .flexible ? 100 : nil)
            .fixedSize(horizontal: size == .regular, vertical: false)
            .contentShape(Rectangle())
            .background(backgroundView(isPressed: configuration.isPressed))
            .foregroundColor(foregroundColor)
            .clipShape(Capsule())
            .shadow(
                color: shadowColor,
                radius: role == .primary ? 6 : 4,
                y: role == .primary ? 3 : 2
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(DS.Animation.microInteraction, value: configuration.isPressed)
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
            if isPressed {
                Color.accentColor.opacity(0.8)
            } else {
                DS.Colors.accent
            }
        case .secondary, .destructive:
            if isPressed {
                Color.black.opacity(0.12) // Hover/pressed dim
            } else {
                Rectangle().fill(DS.Materials.platter)
            }
        }
    }

    private var foregroundColor: Color {
        switch role {
        case .primary: return .white
        case .secondary: return DS.Colors.textPrimary
        case .destructive: return DS.Colors.error
        }
    }

    private var shadowColor: Color {
        switch role {
        case .primary: return DS.Colors.accent.opacity(0.3)
        case .secondary, .destructive: return DS.Shadows.ambientColor
        }
    }
}

extension ButtonStyle where Self == ActionButtonStyle {
    static func action(role: ActionButtonRole = .primary, size: ActionButtonSize = .flexible) -> ActionButtonStyle {
        ActionButtonStyle(role: role, size: size)
    }
}
