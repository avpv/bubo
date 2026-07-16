import SwiftUI
import BuboDomain

// MARK: - Quick Add (one-line task capture)
//
// The popover anchored on the footer's «New Event» button, opened via
// its «Quick Add…» menu item or ⇧⌘N: one text field that jots a task
// into the backlog without leaving the popover. Task-only by design —
// events go through the New Event form (the button's primary action,
// user decision 2026-07-16; UX_AUDIT.md F8 amendments), so this surface
// no longer parses times or routes between vocabularies. A trailing
// duration («30m» / «1h30m») is read by `BacklogTitleParser`, exactly
// like the backlog composer, and the interpretation renders live under
// the field in the machine-hint voice (PRINCIPLES §6). ↩ commits with
// an undo toast; ⇧↩ escapes to `NewTaskView` pre-filled; Esc dismisses.
//
// Visual idiom mirrors `QuickCaptureView` (the ⌃⇧⌘Space global panel)
// so the two capture surfaces read as one product — this one is
// popover-sized.
struct QuickAddView: View {
    @Environment(\.activeSkin) private var skin

    /// Commit — title with the duration token stripped, explicit
    /// minutes or nil (the host may consult the guess table).
    let onAdd: (String, Int?) -> Void
    /// ⇧↩ — open `NewTaskView` pre-filled (title, explicit minutes).
    let onDetails: (String, Int?) -> Void
    /// Esc / commit — the host tears the popover down.
    let onDismiss: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private var parsed: (cleaned: String, durationMinutes: Int?) {
        BacklogTitleParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(skin.accentColor)
                    .symbolRenderingMode(.hierarchical)

                TextField(
                    "Add a task\u{2026}",
                    text: $text,
                    prompt: Text("Write report 30m")
                        .foregroundStyle(skin.resolvedTextTertiary)
                )
                .textFieldStyle(.plain)
                .font(.system(.body, design: skin.resolvedFontDesign, weight: .regular))
                .foregroundStyle(skin.resolvedTextPrimary)
                .focused($isFocused)
                .onSubmit { commit() }
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    commitWithDetails()
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
            }

            // Live interpretation — the machine thinking out loud (§6).
            // Empty input renders the hotkey hints instead, so the row
            // never collapses and the popover doesn't jump in height.
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: DS.Spacing.sm) {
                    Text("\u{21A9} Add")
                    Text("\u{00B7}")
                    Text("\u{21E7}\u{21A9} Details")
                    Text("\u{00B7}")
                    Text("Esc to cancel")
                }
                .font(DS.Typography.machineHint)
                .foregroundStyle(skin.resolvedTextTertiary)
            } else {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "circle")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .accessibilityHidden(true)
                    Text(interpretationLabel)
                        .font(DS.Typography.machineHint)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                .accessibilityLabel("Will create \(interpretationLabel)")
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.md)
        .frame(width: 340)
        .onAppear {
            // Same deferred-focus trick as QuickCaptureView — focusing
            // before the popover becomes key loses the keyboard.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                isFocused = true
            }
        }
    }

    // MARK: Interpretation preview

    private var interpretationLabel: String {
        let (title, duration) = parsed
        // Explicit duration reads plain; a guess wears the tilde so
        // the user knows the machine filled it in (§6 convention).
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
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onDismiss()
            return
        }
        let (title, duration) = parsed
        onAdd(title, duration)
        text = ""
        onDismiss()
    }

    private func commitWithDetails() {
        let (title, duration) = parsed
        onDetails(title, duration)
        text = ""
    }
}
