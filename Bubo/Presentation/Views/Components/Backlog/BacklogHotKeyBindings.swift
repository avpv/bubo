import SwiftUI
import BuboDomain

/// Invisible 1-9 hotkey buttons for «complete the Nth visible task».
/// Mounted as `.background(...)` of the popover root so it occupies no
/// visual space but still participates in shortcut routing.
///
/// Gated on `isInputFocused`: when the add-task field is active, digit
/// keys belong to typing — the buttons drop out of the responder chain
/// entirely while focus is on the field.
struct BacklogHotKeyBindings: View {
    let isInputFocused: Bool
    let visibleTasks: [BacklogTask]
    /// Cap on how many digit shortcuts are wired (1…9 → first 9 visible
    /// tasks). Hosts pass `BacklogFullscreenView.maxHotKeyTasks` so the
    /// hotkey list and the row hotkey badges agree on the same cutoff.
    let maxHotKeyTasks: Int
    let onComplete: (BacklogTask) -> Void

    var body: some View {
        if !isInputFocused, !visibleTasks.isEmpty {
            // SF doesn't have a more compact way to register N shortcuts
            // dynamically, so explicit ForEach. `.frame(width: 0, height: 0)`
            // + `.opacity(0)` makes the buttons invisible without removing
            // them from the tree (which would also remove the shortcut).
            ForEach(Array(visibleTasks.prefix(maxHotKeyTasks).enumerated()), id: \.element.id) { index, task in
                Button("Complete task \(index + 1)") {
                    // Hot-key path bypasses the row's checkbox button, so we
                    // fire the same tactile click here. Tap-to-complete via
                    // the checkbox already haptics from `IconPressStyle`'s
                    // host button (`BacklogTaskRow.checkbox`); `complete()`
                    // itself stays haptic-free so the cue follows the user
                    // gesture, not the model mutation.
                    Haptics.tap()
                    onComplete(task)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
    }
}
