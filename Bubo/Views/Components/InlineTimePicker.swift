import SwiftUI

/// Clickable time label that opens a flat dropdown of 30-minute slots.
///
/// No icon, no grouping — just click the time to pick from a list.
///
/// ```swift
/// InlineTimePicker(selection: $date)
/// ```
struct InlineTimePicker: View {
    @Binding var selection: Date

    var step: Int = 30

    private var slots: [Slot] {
        stride(from: 0, to: 24 * 60, by: step).map { Slot(id: $0) }
    }

    private var currentSlotID: Int {
        let cal = Calendar.current
        let h = cal.component(.hour, from: selection)
        let m = cal.component(.minute, from: selection)
        let total = h * 60 + m
        return ((total + step / 2) / step) * step % (24 * 60)
    }

    var body: some View {
        Picker("", selection: Binding(
            get: { currentSlotID },
            set: { newID in
                let slot = Slot(id: newID)
                if let newDate = Calendar.current.date(
                    bySettingHour: slot.hour, minute: slot.minute, second: 0,
                    of: selection
                ) {
                    selection = newDate
                }
            }
        )) {
            ForEach(slots) { slot in
                Text(slot.label).tag(slot.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - Slot

    private struct Slot: Identifiable {
        let id: Int // total minutes from midnight
        var hour: Int { id / 60 }
        var minute: Int { id % 60 }
        var label: String { String(format: "%02d:%02d", hour, minute) }
    }
}
