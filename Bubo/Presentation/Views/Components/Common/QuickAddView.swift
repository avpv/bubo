import SwiftUI
import BuboDomain

// MARK: - Quick Add (unified front door)
//
// The popover behind the footer's primary «Add» button (UX_AUDIT.md F8):
// one text field that accepts a thought and routes it — an explicit
// clock time makes it an event, everything else is a task
// (`QuickAddParser`). The interpretation renders live under the field
// in the machine-hint voice (PRINCIPLES §6), so the user always sees
// what ↩ will create before pressing it. ⇧↩ escapes to the full form
// pre-filled; Esc dismisses.
//
// Visual idiom mirrors `QuickCaptureView` (the ⇧⌘N global panel) so the
// two capture surfaces read as one product — this one is popover-sized
// and event-capable.
struct QuickAddView: View {
    @Environment(\.activeSkin) private var skin

    /// Commit a task interpretation (title, explicit duration or nil).
    let onAddTask: (String, Int?) -> Void
    /// Commit an event interpretation (title, start, minutes).
    let onAddEvent: (String, Date, Int) -> Void
    /// ⇧↩ — open the matching detailed form pre-filled.
    let onDetails: (QuickAddParser.Interpretation) -> Void
    /// Esc / commit — the host tears the popover down.
    let onDismiss: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private var interpretation: QuickAddParser.Interpretation {
        QuickAddParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(skin.accentColor)
                    .symbolRenderingMode(.hierarchical)

                TextField(
                    "Add anything\u{2026}",
                    text: $text,
                    prompt: Text("Write report 30m \u{00B7} Lunch with Anna 13:00")
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
                    Image(systemName: interpretationIcon)
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

    private var interpretationIcon: String {
        switch interpretation {
        case .task:  return "circle"
        case .event: return "calendar"
        }
    }

    private var interpretationLabel: String {
        switch interpretation {
        case .task(let title, let duration):
            // Explicit duration reads plain; a guess wears the tilde so
            // the user knows the machine filled it in (§6 convention).
            let minutes = duration
                ?? BacklogTitleParser.guessDuration(for: title)
            if let minutes {
                let prefix = duration == nil ? "~" : ""
                return "Task \u{00B7} \(prefix)\(DS.formatMinutes(minutes))"
            }
            return "Task"
        case .event(_, let start, let minutes):
            let end = start.addingTimeInterval(TimeInterval(minutes * 60))
            let day: String
            if Calendar.current.isDateInToday(start) {
                day = "Today"
            } else if Calendar.current.isDateInTomorrow(start) {
                day = "Tomorrow"
            } else {
                day = start.formatted(date: .abbreviated, time: .omitted)
            }
            let startStr = start.formatted(date: .omitted, time: .shortened)
            let endStr = end.formatted(date: .omitted, time: .shortened)
            return "Event \u{00B7} \(day) \(startStr)\u{2013}\(endStr)"
        }
    }

    // MARK: Commit

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onDismiss()
            return
        }
        switch QuickAddParser.parse(trimmed) {
        case .task(let title, let duration):
            onAddTask(title, duration)
        case .event(let title, let start, let minutes):
            onAddEvent(title, start, minutes)
        }
        text = ""
        onDismiss()
    }

    private func commitWithDetails() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        onDetails(QuickAddParser.parse(trimmed))
        text = ""
    }
}
