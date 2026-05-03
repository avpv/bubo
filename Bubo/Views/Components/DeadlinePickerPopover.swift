import SwiftUI

/// Inline deadline picker shown as a popover from the backlog row's
/// «Set deadline…» context-menu item. Re-uses the system `DatePicker`
/// (Birman: «don't undermine trust with a custom solution when a
/// system one exists»), wraps it in the same platter chrome `AddEventView`
/// uses so the popover reads as part of the app's design language.
///
/// State is local: the picker holds a draft date that's committed only
/// when the user taps Save. Cancel discards. A trailing «Clear» button
/// (rendered when the task already has a deadline) lets the user wipe
/// the deadline without opening the full editor — Birman: each scope
/// command lives next to its object.
struct DeadlinePickerPopover: View {
    let initialDeadline: Date?
    let title: String
    /// Save the draft date as the new deadline. nil clears.
    let onSave: (Date?) -> Void
    /// Dismiss without writing.
    let onCancel: () -> Void

    @Environment(\.activeSkin) private var skin

    @State private var draft: Date

    init(
        initialDeadline: Date?,
        title: String,
        onSave: @escaping (Date?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialDeadline = initialDeadline
        self.title = title
        self.onSave = onSave
        self.onCancel = onCancel
        // Default the picker to the existing deadline, or end of today —
        // matches `Mark urgent`'s today-end choice so adjacent commands
        // produce the same shape of result.
        let defaultDate = initialDeadline
            ?? Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date())
            ?? Date()
        _draft = State(initialValue: defaultDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text("Deadline for \u{201C}\(title)\u{201D}")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(skin.resolvedTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            // System DatePicker — date + time. Time matters for «end of
            // day» semantics in `BacklogLogic.isUrgent` so the row's
            // urgency stripe aligns with the user's intent.
            DatePicker("", selection: $draft)
                .labelsHidden()
                .datePickerStyle(.graphical)

            HStack(spacing: DS.Spacing.sm) {
                if initialDeadline != nil {
                    Button(role: .destructive) {
                        Haptics.tap()
                        onSave(nil)
                    } label: {
                        Text("Clear")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(skin.resolvedDestructiveColor)
                }

                Spacer()

                Button {
                    Haptics.tap()
                    onCancel()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)

                Button {
                    Haptics.tap()
                    onSave(draft)
                } label: {
                    Text("Save")
                        .fontWeight(.medium)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.plain)
                .foregroundStyle(skin.accentColor)
            }
        }
        .padding(DS.Spacing.md)
        .frame(minWidth: 320)
    }
}
