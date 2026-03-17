import SwiftUI

/// A combobox-style time picker for macOS menu bar apps.
///
/// Click the displayed time → native `NSMenu` with 30-min slot presets
/// grouped by Morning / Afternoon / Evening. Nearest slot is marked.
///
/// For manual entry, the caller should show a `DatePicker` separately
/// (e.g. in a disclosure group), keeping this control focused on quick selection.
///
/// ```swift
/// TimeSlotPicker(selection: $date, step: 30)
/// ```
struct TimeSlotPicker: View {
    @Binding var selection: Date
    var step: Int = 30

    var body: some View {
        let nearest = nearestSlotID

        Menu {
            Section("Morning") {
                slotButtons(from: 0, to: Self.noon, nearest: nearest)
            }
            Section("Afternoon") {
                slotButtons(from: Self.noon, to: Self.evening, nearest: nearest)
            }
            Section("Evening") {
                slotButtons(from: Self.evening, to: Self.midnight, nearest: nearest)
            }
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Text(DS.timeFormatter.string(from: selection))
                    .monospacedDigit()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Size.cornerRadius)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.cornerRadius)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
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
    private func slotButtons(from lower: Int, to upper: Int, nearest: Int) -> some View {
        ForEach(Self.makeSlots(step: step).filter({ $0.id >= lower && $0.id < upper })) { slot in
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
