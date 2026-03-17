import SwiftUI

// MARK: - Design Tokens

/// Centralized design system for consistent spacing, sizing, typography, and colors.
enum DS {

    // MARK: Spacing Scale (4-point grid)

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 30
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
        static let iconSize: CGFloat = 36
        static let spacing: CGFloat = 10
    }

    // MARK: Component Sizes

    enum Size {
        static let accentBarWidth: CGFloat = 3
        static let accentBarHeight: CGFloat = 28
        static let timeColumnWidth: CGFloat = 50
        static let iconSmall: CGFloat = 12
        static let iconMedium: CGFloat = 13
        static let iconLarge: CGFloat = 14
        static let headerIcon: CGFloat = 18
        static let cornerRadius: CGFloat = 6
        static let badgeCornerRadius: CGFloat = 4
        static let syncIndicatorSize: CGFloat = 14
        static let todayDotSize: CGFloat = 6
    }

    // MARK: Animation

    enum Animation {
        static let quick: SwiftUI.Animation = .easeInOut(duration: 0.15)
        static let standard: SwiftUI.Animation = .easeInOut(duration: 0.2)
        static let entrance: SwiftUI.Animation = .easeOut(duration: 0.3)
    }

    // MARK: Urgency Colors

    static func urgencyColor(minutesUntil: Int) -> Color {
        if minutesUntil <= 5 { return .red }
        if minutesUntil <= 15 { return .orange }
        return .green
    }

    // MARK: Countdown Colors

    static func countdownColor(secondsRemaining: Int) -> Color {
        if secondsRemaining <= 120 { return .red }
        if secondsRemaining <= 300 { return .orange }
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
            self.label = "\(minutes) minutes"
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

// MARK: - Form Fields

/// Styled text field for use inside `Form { }` with `.formStyle(.grouped)`.
/// Renders as a standard macOS labeled row with a rounded-border input.
struct FormTextField: View {
    let label: String
    var prompt: String? = nil
    @Binding var text: String
    var isSecure: Bool = false

    var body: some View {
        LabeledContent(label) {
            Group {
                if isSecure {
                    SecureField(text: $text, prompt: promptText)
                } else {
                    TextField(text: $text, prompt: promptText)
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private var promptText: Text? {
        prompt.map { Text($0).foregroundColor(.tertiary) }
    }
}

// MARK: - Reusable Header

/// Standard header bar used across popover views.
struct PopoverHeader: View {
    var title: String? = nil
    var showBack: Bool = false
    var onBack: (() -> Void)? = nil
    var trailing: AnyView? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.xs) {
                if showBack {
                    Button {
                        onBack?()
                    } label: {
                        HStack(spacing: DS.Spacing.xxs) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: DS.Size.iconMedium, weight: .semibold))
                            Text("Back")
                                .font(.subheadline)
                        }
                    }
                    .buttonStyle(.borderless)
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
            .background(.bar)

            Divider()
        }
    }
}
