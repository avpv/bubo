import SwiftUI

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
                    .onKeyPress(.escape) {
                        onCancel()
                        return .handled
                    }
            }

            HStack(spacing: DS.Spacing.sm) {
                Text("\u{21A9} Add")
                    .font(DS.Typography.machineHint)
                    .foregroundStyle(skin.resolvedTextTertiary)
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
}
