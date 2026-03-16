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
final class ToastState: ObservableObject {
    @Published var current: ToastMessage?
    private var dismissTask: DispatchWorkItem?

    func show(_ message: ToastMessage, duration: TimeInterval = 2.5) {
        dismissTask?.cancel()
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
    @ObservedObject var toastState: ToastState

    var body: some View {
        VStack {
            Spacer()
            if let toast = toastState.current {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: toast.icon)
                        .font(.caption)
                        .foregroundColor(toast.color)
                    Text(toast.text)
                        .font(.caption)
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .padding(.bottom, DS.Spacing.md)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStatusElement)
            }
        }
        .animation(DS.Animation.standard, value: toastState.current?.id)
    }
}
