import SwiftUI

/// A toast message shown briefly after user actions.
struct ToastMessage: Equatable, Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let style: Style
    /// Optional undo action — when provided, toast shows an "Undo" button (HIG: Undo support).
    var onUndo: (() -> Void)?

    enum Style {
        case success, info, warning
    }

    func color(for skin: SkinDefinition) -> Color {
        switch style {
        case .success: return skin.resolvedSuccessColor
        case .info: return DS.Colors.info
        case .warning: return skin.resolvedWarningColor
        }
    }

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool {
        lhs.id == rhs.id
    }
}

/// Observable toast state manager.
@Observable
final class ToastState {
    var current: ToastMessage?
    private var dismissTask: DispatchWorkItem?

    func show(_ message: ToastMessage, duration: TimeInterval = 2.5) {
        dismissTask?.cancel()
        Haptics.tap()
        // Show undo toasts longer so users have time to react
        let effectiveDuration = message.onUndo != nil ? max(duration, 4.0) : duration
        withAnimation(DS.Animation.standard) {
            current = message
        }
        let task = DispatchWorkItem { [weak self] in
            withAnimation(DS.Animation.standard) {
                self?.current = nil
            }
        }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDuration, execute: task)
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(DS.Animation.standard) {
            current = nil
        }
    }

    func showSuccess(_ text: String, icon: String = "checkmark.circle.fill", onUndo: (() -> Void)? = nil) {
        show(ToastMessage(icon: icon, text: text, style: .success, onUndo: onUndo))
    }

    func showInfo(_ text: String, icon: String = "info.circle.fill") {
        show(ToastMessage(icon: icon, text: text, style: .info))
    }
}

/// Toast overlay view, placed at bottom of popover.
struct ToastOverlay: View {
    let toastState: ToastState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.activeSkin) private var skin

    var body: some View {
        VStack {
            Spacer()
            if let toast = toastState.current {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: toast.icon)
                        .font(.caption)
                        .foregroundStyle(toast.color(for: skin))
                        .contentTransition(.symbolEffect(.replace))
                    Text(toast.text)
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextPrimary)

                    // HIG: Provide undo for destructive actions
                    if let onUndo = toast.onUndo {
                        Button {
                            Haptics.tap()
                            onUndo()
                            toastState.dismiss()
                        } label: {
                            Text("Undo")
                                .font(.caption)
                                .fontWeight(skin.resolvedFontWeight)
                                .foregroundStyle(skin.accentColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Undo action")
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
                .background(skin.resolvedPlatterMaterial)
                .clipShape(Capsule())
                .shadow(color: skin.resolvedShadowColor, radius: DS.Shadows.toastRadius, y: DS.Shadows.toastY)
                .padding(.bottom, DS.Spacing.md)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)),
                            removal: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.95))
                        )
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Status: \(toast.text)\(toast.onUndo != nil ? ". Undo available." : "")")
            }
        }
        .animation(
            reduceMotion ? DS.Animation.quick : DS.Animation.gentleBounce,
            value: toastState.current?.id
        )
    }
}
