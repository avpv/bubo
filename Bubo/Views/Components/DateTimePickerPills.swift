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
                .padding(.vertical, DS.Spacing.pillVertical)
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
                .padding(.vertical, DS.Spacing.pillVertical)
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
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .fixedSize(horizontal: true, vertical: false)
            }
            .layoutPriority(1)
        }
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
