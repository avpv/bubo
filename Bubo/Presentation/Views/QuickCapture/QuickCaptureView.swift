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
//
// A trailing duration («30m» / «1h30m») is read by `BacklogTitleParser`
// — the same parser the in-popover Quick Add and the backlog composer
// trust — and previewed live under the field in the machine-hint voice
// (PRINCIPLES §6). The view still forwards the raw text; the menu-bar
// listener (`handleCapturedBacklogTask`) re-runs the same parse on
// commit, so the preview is a promise, not a separate code path.

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
                    .font(.system(.title3, design: skin.resolvedFontDesign, weight: .regular))
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

            // Hotkey hints at rest; the live interpretation once there
            // is text — mirrors `QuickAddView` so the two one-line
            // captures read as one product. Either way the row keeps
            // its height, so the panel never jumps.
            HStack(spacing: DS.Spacing.sm) {
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("\u{21A9} Add")
                    if onSubmitWithDetails != nil {
                        Text("\u{00B7}")
                        Text("\u{21E7}\u{21A9} Details")
                    }
                    Text("\u{00B7}")
                    Text("Esc to cancel")
                } else {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "circle")
                            .font(.caption)
                            .accessibilityHidden(true)
                        Text(interpretationLabel)
                    }
                    .accessibilityLabel("Will create \(interpretationLabel)")
                }
                Spacer(minLength: DS.Spacing.sm)
                Text("Bubo \u{00B7} Quick capture")
            }
            .font(DS.Typography.machineHint)
            .foregroundStyle(skin.resolvedTextTertiary)
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

    // MARK: Interpretation preview

    /// Same label logic as `QuickAddView.interpretationLabel`: an
    /// explicit duration reads plain, a verb-table guess wears the
    /// tilde so the user knows the machine filled it in (§6).
    private var interpretationLabel: String {
        let (title, duration) = BacklogTitleParser.parse(text)
        let minutes = duration
            ?? BacklogTitleParser.guessDuration(for: title)
        if let minutes {
            let prefix = duration == nil ? "~" : ""
            return "Task \u{00B7} \(prefix)\(DS.formatMinutes(minutes))"
        }
        return "Task"
    }

    // MARK: Commit

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
