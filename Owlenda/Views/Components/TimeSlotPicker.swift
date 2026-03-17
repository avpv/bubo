import SwiftUI

/// Compact quick-preset button for time selection.
///
/// Shows a clock icon that opens a native `NSMenu` with 30-min slot
/// presets grouped by Morning / Afternoon / Evening. Designed to sit
/// next to a `DatePicker(.hourAndMinute)` — the DatePicker handles
/// display and manual entry, this button handles quick preset selection.
///
/// ```swift
/// HStack {
///     TimeSlotPicker(selection: $date)
///     DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
/// }
/// ```
struct TimeSlotPicker: View {
    @Binding var selection: Date
    var step: Int = 30

    var body: some View {
        let nearest = nearestSlotID
        let allSlots = Self.makeSlots(step: step)

        Menu {
            Section("Morning") {
                slotButtons(allSlots.filter { $0.id < Self.noon }, nearest: nearest)
            }
            Section("Afternoon") {
                slotButtons(allSlots.filter { $0.id >= Self.noon && $0.id < Self.evening }, nearest: nearest)
            }
            Section("Evening") {
                slotButtons(allSlots.filter { $0.id >= Self.evening }, nearest: nearest)
            }
        } label: {
            Image(systemName: "clock")
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Constants

    private static let noon = 12 * 60       // 12:00
    private static let evening = 18 * 60    // 18:00
    private static let midnight = 24 * 60   // 24:00

    // MARK: - Slots

    private struct Slot: Identifiable {
        let id: Int // total minutes from midnight
        var hour: Int { id / 60 }
        var minute: Int { id % 60 }
        var label: String { String(format: "%02d:%02d", hour, minute) }
    }

    private static func makeSlots(step: Int) -> [Slot] {
        stride(from: 0, to: midnight, by: step).map { Slot(id: $0) }
    }

    /// Computed once per body evaluation and passed down — not recomputed per slot.
    private var nearestSlotID: Int {
        let cal = Calendar.current
        let mins = cal.component(.hour, from: selection) * 60
            + cal.component(.minute, from: selection)
        let rounded = ((mins + step / 2) / step) * step
        return min(rounded, Self.midnight - step)
    }

    @ViewBuilder
    private func slotButtons(_ slots: [Slot], nearest: Int) -> some View {
        ForEach(slots) { slot in
            Button {
                selection = apply(slot)
            } label: {
                if slot.id == nearest {
                    Label(slot.label, systemImage: "smallcircle.filled.circle")
                } else {
                    Text(slot.label)
                }
            }
        }
    }

    private func apply(_ slot: Slot) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: selection)
        comps.hour = slot.hour
        comps.minute = slot.minute
        comps.second = 0
        return cal.date(from: comps) ?? selection
    }
}
