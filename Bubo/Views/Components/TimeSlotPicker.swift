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
                            TimeSlotChip(
                                slot: slot,
                                isSelected: slot.id == nearest,
                                action: { selection = apply(slot) }
                            )
                            .id(slot.id)
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
                    .onChange(of: selection) {
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
    fileprivate struct Slot: Identifiable {
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

fileprivate struct TimeSlotChip: View {
    let slot: TimeSlotPicker.Slot
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.activeSkin) private var skin

    private var chipAccent: Color {
        skin.isClassic ? DS.Colors.accent : skin.accentColor
    }

    var body: some View {
        Button(action: {
            Haptics.tap()
            action()
        }) {
            Text(slot.label)
                .font(.system(.body, design: .monospaced, weight: isSelected ? .bold : .regular))
                .foregroundColor(isSelected ? .white : DS.Colors.textPrimary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.Spacing.sm)
        .frame(height: DS.Size.controlHeight)
        .background(
            ZStack {
                if isSelected {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [chipAccent, skin.resolvedSecondaryAccent],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                } else {
                    Capsule()
                        .fill(DS.Materials.platter)
                    if isHovered {
                        Capsule()
                            .fill(chipAccent.opacity(0.08))
                    }
                }
            }
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    isSelected
                        ? .white.opacity(0.2)
                        : (isHovered ? chipAccent.opacity(0.3) : .clear),
                    lineWidth: 0.5
                )
        )
        .shadow(
            color: isSelected ? chipAccent.opacity(0.3) : (isHovered ? DS.Shadows.hoverColor : .clear),
            radius: isSelected ? 6 : (isHovered ? DS.Shadows.hoverRadius : 0),
            y: isSelected ? 3 : (isHovered ? DS.Shadows.hoverY : 0)
        )
        .scaleEffect(isHovered && !isSelected ? 1.03 : 1.0)
        .animation(DS.Animation.microInteraction, value: isHovered)
        .animation(DS.Animation.microInteraction, value: isSelected)
        .contentShape(Capsule())
        #if os(macOS)
        .onHover { hovering in
            withAnimation(DS.Animation.microInteraction) {
                isHovered = hovering
            }
            if hovering && !isSelected {
                NSCursor.pointingHand.push()
                Haptics.generic()
            } else {
                NSCursor.pop()
            }
        }
        #endif
    }
}
