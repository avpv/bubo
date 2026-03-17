import SwiftUI

/// A combobox-style time picker: click to see 30-min slot suggestions,
/// with an always-visible native DatePicker for arbitrary manual entry.
///
/// Usage:
/// ```swift
/// TimeSlotPicker(selection: $date, step: 30)
/// ```
struct TimeSlotPicker: View {
    @Binding var selection: Date
    var step: Int = 30

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            slotMenu
            DatePicker("", selection: $selection, displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
    }

    // MARK: - Slot Menu

    private var slotMenu: some View {
        Menu {
            ForEach(slots) { slot in
                Button {
                    selection = apply(slot)
                } label: {
                    if slot == nearest {
                        Label(slot.label, systemImage: "smallcircle.filled.circle")
                    } else {
                        Text(slot.label)
                    }
                }
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

    // MARK: - Slot Model & Generation

    private struct Slot: Identifiable, Equatable {
        let id: Int          // total minutes from midnight
        var hour: Int { id / 60 }
        var minute: Int { id % 60 }
        var label: String { String(format: "%02d:%02d", hour, minute) }
    }

    /// All slots for the day based on `step`.
    private var slots: [Slot] {
        stride(from: 0, to: 24 * 60, by: step).map { Slot(id: $0) }
    }

    /// Nearest slot to the current selection (for visual indicator).
    private var nearest: Slot? {
        let cal = Calendar.current
        let mins = cal.component(.hour, from: selection) * 60
            + cal.component(.minute, from: selection)
        let rounded = ((mins + step / 2) / step) * step
        let clamped = min(rounded, 24 * 60 - step)
        return Slot(id: clamped)
    }

    /// Apply a slot's time to the current selection date.
    private func apply(_ slot: Slot) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: selection)
        comps.hour = slot.hour
        comps.minute = slot.minute
        comps.second = 0
        return cal.date(from: comps) ?? selection
    }
}
