import SwiftUI

/// Compact quick-preset horizontal scroll for time selection.
///
/// Shows a horizontal list of 30-min slot chips. Designed to sit
/// next to a `DatePicker(.hourAndMinute)` — the DatePicker handles
/// display and manual entry, this ribbon handles quick preset selection.
///
/// When the selected date is today, past slots are hidden entirely.
/// If no future slots remain, it shows a text placeholder.
struct TimeSlotPicker: View {
    @Binding var selection: Date
    var step: Int = 30

    /// Re-evaluated every minute so past slots disappear in real time.
    @State private var now = Date()
    @State private var hasScrolledToInitial = false

    var body: some View {
        let slots = availableSlots
        let nearest = nearestAvailableSlotID(in: slots)

        if slots.isEmpty {
            Text("No slots left today")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, DS.Spacing.xs)
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        now = .now
                    }
                }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                ScrollViewReader { proxy in
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(slots) { slot in
                            Button {
                                selection = apply(slot)
                            } label: {
                                Text(slot.label)
                                    .font(.caption)
                                    .fontWeight(slot.id == nearest ? .semibold : .regular)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(slot.id == nearest ? DS.Colors.accent : DS.Colors.badgeFill(DS.Colors.textPrimary))
                            )
                            .foregroundColor(slot.id == nearest ? .white : DS.Colors.textPrimary)
                            .id(slot.id)
                            #if os(macOS)
                            .onHover { isHovered in
                                if slot.id != nearest && isHovered {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            #endif
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 2)
                    .onAppear {
                        if !hasScrolledToInitial, let nearestId = nearest {
                            proxy.scrollTo(nearestId, anchor: .center)
                            hasScrolledToInitial = true
                        }
                    }
                    .onChange(of: selection) { _ in
                        if let nearestId = nearestAvailableSlotID(in: slots) {
                            withAnimation(DS.Animation.microInteraction) {
                                proxy.scrollTo(nearestId, anchor: .center)
                            }
                        }
                    }
                }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    now = .now
                }
            }
        }
    }

    // MARK: - Constants
    private static let midnight = 24 * 60

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

    private var availableSlots: [Slot] {
        let cutoff = currentMinutesCutoff
        return stride(from: 0, to: Self.midnight, by: step)
            .filter { $0 >= cutoff }
            .map { Slot(id: $0) }
    }

    /// Nearest slot to current selection, clamped to actually visible slots.
    private func nearestAvailableSlotID(in slots: [Slot]) -> Int? {
        let cal = Calendar.current
        let mins = cal.component(.hour, from: selection) * 60
            + cal.component(.minute, from: selection)
        let rounded = ((mins + step / 2) / step) * step
        let target = min(rounded, Self.midnight - step)

        let allIDs = slots.map(\.id)
        guard !allIDs.isEmpty else { return nil }

        // Find the closest visible slot to the target.
        return allIDs.min(by: { abs($0 - target) < abs($1 - target) })
    }

    private func apply(_ slot: Slot) -> Date {
        Calendar.current.date(
            bySettingHour: slot.hour, minute: slot.minute, second: 0,
            of: selection
        ) ?? selection
    }
}
