import SwiftUI

/// A toast message shown briefly after user actions.
struct ToastMessage: Equatable, Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let style: Style

    enum Style {
        case success, info, warning
    }

    var color: Color {
        switch style {
        case .success: return .green
        case .info: return .blue
        case .warning: return .orange
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
        Haptics.generic()
        withAnimation(DS.Animation.standard) {
            current = message
        }
        let task = DispatchWorkItem { [weak self] in
            withAnimation(DS.Animation.standard) {
                self?.current = nil
            }
        }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }

    func showSuccess(_ text: String, icon: String = "checkmark.circle.fill") {
        show(ToastMessage(icon: icon, text: text, style: .success))
    }

    func showInfo(_ text: String, icon: String = "info.circle.fill") {
        show(ToastMessage(icon: icon, text: text, style: .info))
    }
}

/// Toast overlay view, placed at bottom of popover.
struct ToastOverlay: View {
    let toastState: ToastState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Spacer()
            if let toast = toastState.current {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: toast.icon)
                        .font(.caption)
                        .foregroundColor(toast.color)
                        .contentTransition(.symbolEffect(.replace))
                    Text(toast.text)
                        .font(.caption)
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
                .background(DS.Materials.toast)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
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
                .accessibilityLabel("Status: \(toast.text)")
            }
        }
        .animation(
            reduceMotion ? DS.Animation.quick : DS.Animation.gentleBounce,
            value: toastState.current?.id
        )
    }
}
