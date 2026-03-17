import SwiftUI

/// Compact quick-preset button for time selection.
///
/// Shows a clock icon that opens a native `NSMenu` with 30-min slot
/// presets grouped by Morning / Afternoon / Evening. Designed to sit
/// next to a `DatePicker(.hourAndMinute)` — the DatePicker handles
/// display and manual entry, this button handles quick preset selection.
///
/// When the selected date is today, past slots are hidden entirely.
/// A per-minute task keeps the list up to date while the form is open.
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

    /// Re-evaluated every minute so past slots disappear in real time.
    @State private var now = Date()

    var body: some View {
        let nearest = nearestSlotID
        let groups = sectionedSlots

        Menu {
            ForEach(groups) { group in
                Section(group.title) {
                    slotButtons(group.slots, nearest: nearest)
                }
            }
        } label: {
            Image(systemName: "clock")
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .task(id: "minute-tick") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = .now
            }
        }
    }

    // MARK: - Section model

    private struct SlotSection: Identifiable {
        let title: String
        let slots: [Slot]
        var id: String { title }
    }

    private static let sections: [(String, Range<Int>)] = [
        ("Morning",   0 ..< noon),
        ("Afternoon", noon ..< evening),
        ("Evening",   evening ..< midnight),
    ]

    /// Slots grouped by time-of-day, with past slots and empty sections removed.
    private var sectionedSlots: [SlotSection] {
        let cutoff = currentMinutesCutoff
        return Self.sections.compactMap { title, range in
            let slots = stride(from: range.lowerBound, to: range.upperBound, by: step)
                .filter { $0 >= cutoff }
                .map { Slot(id: $0) }
            guard !slots.isEmpty else { return nil }
            return SlotSection(title: title, slots: slots)
        }
    }

    // MARK: - Constants

    private static let noon = 12 * 60       // 12:00
    private static let evening = 18 * 60    // 18:00
    private static let midnight = 24 * 60   // 24:00

    // MARK: - Slot

    private struct Slot: Identifiable {
        let id: Int // total minutes from midnight
        var hour: Int { id / 60 }
        var minute: Int { id % 60 }
        var label: String { String(format: "%02d:%02d", hour, minute) }
    }

    /// Minutes-from-midnight cutoff: slots before this value are hidden.
    /// Returns `0` when the selected date is not today (all slots visible).
    private var currentMinutesCutoff: Int {
        let cal = Calendar.current
        guard cal.isDateInToday(selection) else { return 0 }
        return cal.component(.hour, from: now) * 60
            + cal.component(.minute, from: now)
    }

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
