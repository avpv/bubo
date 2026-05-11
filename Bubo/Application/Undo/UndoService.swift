import Foundation

// MARK: - Undo Service

/// Centralized undo system. Replaces "Are you sure?" dialogs
/// with instant action + undo toast (per Birman's design principles).
///
/// Any destructive action pushes an UndoAction onto the stack.
/// The UI shows a toast with "Undo" for a few seconds.
/// If the user taps Undo, the closure is executed to reverse the action.
@MainActor
@Observable
final class UndoService {

    /// The most recent undoable action (shown as toast).
    private(set) var lastAction: UndoAction?

    /// Whether the undo toast is currently visible.
    private(set) var isShowingToast: Bool = false

    private var dismissTask: Task<Void, Never>?

    /// Register an undoable action. Shows toast for `duration` seconds.
    func push(_ label: String, duration: TimeInterval = 5, undo: @escaping () -> Void) {
        // Cancel previous dismiss timer
        dismissTask?.cancel()

        let action = UndoAction(label: label, undo: undo)
        lastAction = action
        isShowingToast = true

        // Auto-dismiss after duration
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            if !Task.isCancelled {
                dismiss()
            }
        }
    }

    /// Execute undo and dismiss toast.
    func performUndo() {
        dismissTask?.cancel()
        lastAction?.undo()
        dismiss()
    }

    /// Dismiss toast without undoing.
    func dismiss() {
        isShowingToast = false
        lastAction = nil
    }
}

// MARK: - Undo Action

struct UndoAction {
    let label: String
    let undo: () -> Void
    let createdAt = Date()
}
