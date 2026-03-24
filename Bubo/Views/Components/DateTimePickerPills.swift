import SwiftUI

struct DateTimePickerPills: View {
    @Binding var date: Date
    var range: PartialRangeFrom<Date>?

    @State private var showDatePopover = false
    @State private var showTimePopover = false

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            // Date Pill
            Button(action: { showDatePopover.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .foregroundColor(DS.Colors.accent)
                    Text(formattedDate)
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: DS.Size.datePillWidth, alignment: .leading)
                        .mask(
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .black, location: 0.85),
                                    .init(color: .clear, location: 1.0)
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
                .padding(.horizontal, DS.Spacing.pillHorizontal)
                .frame(height: DS.Size.controlHeight)
                .background(DS.Materials.platter)
                .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.pillRadius, y: DS.Shadows.pillY)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDatePopover, arrowEdge: .bottom) {
                DateSuggestionsPopover(date: $date, isPresented: $showDatePopover, range: range)
            }
            .layoutPriority(1)
            
            // Time Pill
            Button(action: { showTimePopover.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(formattedTime)
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: true, vertical: false)
                        .lineLimit(1)
                }
                .padding(.horizontal, DS.Spacing.pillHorizontal)
                .frame(height: DS.Size.controlHeight)
                .background(DS.Materials.platter)
                .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.pillRadius, y: DS.Shadows.pillY)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showTimePopover, arrowEdge: .bottom) {
                VStack(spacing: DS.Spacing.sm) {
                    Text("Select Time")
                        .font(.caption)
                        .foregroundColor(DS.Colors.textSecondary)

                    if let range = range {
                        DatePicker("", selection: $date, in: range, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.stepperField)
                    } else {
                        DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.stepperField)
                    }

                    Divider()

                    let slots = nearestTimeSlots(around: date, count: 7, rangeStart: range?.lowerBound)
                    VStack(spacing: DS.Spacing.xs) {
                        ForEach(slots, id: \.self) { slot in
                            Button(action: {
                                Haptics.tap()
                                date = slot
                            }) {
                                Text(formattedSlotTime(slot))
                                    .font(.body.monospacedDigit())
                                    .foregroundColor(
                                        Calendar.current.compare(slot, to: date, toGranularity: .minute) == .orderedSame
                                            ? .white : DS.Colors.textPrimary
                                    )
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, DS.Spacing.xs)
                                    .background(
                                        RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                                            .fill(
                                                Calendar.current.compare(slot, to: date, toGranularity: .minute) == .orderedSame
                                                    ? DS.Colors.accent : Color.clear
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .fixedSize(horizontal: true, vertical: false)
            }
            .layoutPriority(1)
        }
    }
    
    private func nearestTimeSlots(around date: Date, count: Int, rangeStart: Date?) -> [Date] {
        let cal = Calendar.current
        let mins = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        let rounded = ((mins + 15) / 30) * 30 // round to nearest 30-min
        let half = count / 2

        var slots: [Date] = []
        for i in -half...(count - half - 1) {
            let slotMins = rounded + i * 30
            guard slotMins >= 0 && slotMins < 24 * 60 else { continue }
            if let d = cal.date(bySettingHour: slotMins / 60, minute: slotMins % 60, second: 0, of: date) {
                if let rangeStart, d < rangeStart { continue }
                slots.append(d)
            }
        }
        // Pad if we lost slots at boundaries
        if slots.count < count {
            let needed = count - slots.count
            if let first = slots.first {
                let firstMins = cal.component(.hour, from: first) * 60 + cal.component(.minute, from: first)
                // Try adding before
                for i in 1...needed {
                    let m = firstMins - i * 30
                    if m >= 0, let d = cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: date) {
                        if let rangeStart, d < rangeStart { continue }
                        slots.insert(d, at: 0)
                    }
                }
            }
            if slots.count < count, let last = slots.last {
                let lastMins = cal.component(.hour, from: last) * 60 + cal.component(.minute, from: last)
                for i in 1...(count - slots.count) {
                    let m = lastMins + i * 30
                    if m < 24 * 60, let d = cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: date) {
                        slots.append(d)
                    }
                }
            }
        }
        return Array(slots.prefix(count))
    }

    private func formattedSlotTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "Today"
        } else if cal.isDateInTomorrow(date) {
            return "Tomorrow"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: date)
        }
    }
    
    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
