import SwiftUI

/// A single-control time picker: click the displayed time to open a popover
/// with a scrollable list of 30-min slots (auto-scrolled to nearest) and
/// a native DatePicker for arbitrary manual entry.
///
/// ```swift
/// TimeSlotPicker(selection: $date, step: 30)
/// ```
struct TimeSlotPicker: View {
    @Binding var selection: Date
    var step: Int = 30

    @State private var isOpen = false

    // Pre-computed once based on step; stable across renders.
    private var slots: [Slot] {
        Self.makeSlots(step: step)
    }

    var body: some View {
        Button {
            isOpen.toggle()
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
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            popoverContent
        }
    }

    // MARK: - Popover Content

    private var nearestSlotID: Int {
        let cal = Calendar.current
        let mins = cal.component(.hour, from: selection) * 60
            + cal.component(.minute, from: selection)
        let rounded = ((mins + step / 2) / step) * step
        return min(rounded, 24 * 60 - step)
    }

    private var popoverContent: some View {
        VStack(spacing: 0) {
            // Manual entry
            HStack {
                Text("Custom")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                DatePicker("", selection: $selection, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)

            Divider()

            // Scrollable slot list, grouped by morning/afternoon/evening
            ScrollViewReader { proxy in
                List {
                    slotSection("Morning", range: 0..<720, proxy: proxy)
                    slotSection("Afternoon", range: 720..<1080, proxy: proxy)
                    slotSection("Evening", range: 1080..<1440, proxy: proxy)
                }
                .listStyle(.plain)
                .frame(width: 180, height: 220)
                .onAppear {
                    proxy.scrollTo(nearestSlotID, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func slotSection(_ title: String, range: Range<Int>, proxy: ScrollViewProxy) -> some View {
        let sectionSlots = slots.filter { range.contains($0.id) }
        if !sectionSlots.isEmpty {
            Section(title) {
                ForEach(sectionSlots) { slot in
                    Button {
                        selection = apply(slot)
                        isOpen = false
                    } label: {
                        HStack {
                            Text(slot.label)
                                .monospacedDigit()
                                .foregroundColor(slot.id == nearestSlotID ? .accentColor : .primary)
                            Spacer()
                            if slot.id == nearestSlotID {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 5))
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .id(slot.id)
                }
            }
        }
    }

    // MARK: - Slot Model

    private struct Slot: Identifiable {
        let id: Int // total minutes from midnight
        var hour: Int { id / 60 }
        var minute: Int { id % 60 }
        var label: String { String(format: "%02d:%02d", hour, minute) }
    }

    private static func makeSlots(step: Int) -> [Slot] {
        stride(from: 0, to: 24 * 60, by: step).map { Slot(id: $0) }
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
