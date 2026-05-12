import SwiftUI
import BuboDomain

// MARK: - Global Quick Capture (J5)
//
// One-line, no-fields capture overlay shown by the global hotkey
// (default `⌃⇧⌘Space`). Pure UI; the host (`AppDelegate.QuickCapture`)
// owns the panel window, the hotkey monitor, and the BacklogService
// hand-off via NotificationCenter. Entry → save to backlog → close.
// Esc → close without saving. Keeping the surface free of optional
// fields is the whole point — drop the thought, get back to work.

struct QuickCaptureView: View {
    @Environment(\.activeSkin) private var skin

    /// Called with the trimmed, non-empty title when the user hits
    /// Return. The host translates this into a `BacklogTask.addTask`
    /// via the menu-bar listener so we never bind a service to a view.
    let onSubmit: (String) -> Void
    /// Called on Shift+Return: the user wants the compact creation form
    /// instead of a one-shot add. Host dismisses this panel, opens the
    /// menu-bar popover, and routes to `NewTaskView` with the typed text
    /// pre-filled. Optional so call-sites that haven't wired it up keep
    /// working — when nil, ⇧↩ falls back to the regular submit path.
    var onSubmitWithDetails: ((String) -> Void)? = nil
    /// Called on Esc or click-outside; the host tears down the panel.
    let onCancel: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(skin.accentColor)
                    .symbolRenderingMode(.hierarchical)

                TextField("Add to backlog\u{2026}", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(.title3, design: skin.resolvedFontDesign, weight: .medium))
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .onKeyPress(keys: [.return]) { press in
                        // ⇧↩ — pivot to the detailed creation form. Mirrors
                        // the inline backlog field so muscle memory carries
                        // between surfaces. Plain Return keeps falling
                        // through to `.onSubmit { commit() }` above.
                        guard press.modifiers.contains(.shift) else {
                            return .ignored
                        }
                        commitWithDetails()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        onCancel()
                        return .handled
                    }
            }

            HStack(spacing: DS.Spacing.sm) {
                Text("\u{21A9} Add")
                    .font(DS.Typography.machineHint)
                    .foregroundStyle(skin.resolvedTextTertiary)
                if onSubmitWithDetails != nil {
                    Text("\u{00B7}")
                        .foregroundStyle(skin.resolvedTextTertiary)
                    Text("\u{21E7}\u{21A9} Details")
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                Text("\u{00B7}")
                    .foregroundStyle(skin.resolvedTextTertiary)
                Text("Esc to cancel")
                    .font(DS.Typography.machineHint)
                    .foregroundStyle(skin.resolvedTextTertiary)
                Spacer(minLength: DS.Spacing.sm)
                Text("Bubo \u{00B7} Quick capture")
                    .font(DS.Typography.machineHint)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .frame(width: 480)
        .skinPlatter(skin)
        .skinPlatterDepth(skin, level: .z2)
        .onAppear {
            // Defer focus to the next runloop tick so the panel has
            // already become key — focusing too early loses the
            // keyboard binding to the previous active app.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                isFocused = true
            }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onCancel()
            return
        }
        onSubmit(trimmed)
    }

    /// ⇧↩ path. Forwards the trimmed text (which can be empty —
    /// `NewTaskView` is happy to start blank) to the host so it can pivot
    /// to the detailed form. Falls back to the regular submit path when
    /// no host wired the callback or the text is empty.
    private func commitWithDetails() {
        guard let onSubmitWithDetails else {
            commit()
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        onSubmitWithDetails(trimmed)
    }
}
