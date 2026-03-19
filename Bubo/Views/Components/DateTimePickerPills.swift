import SwiftUI

struct DateTimePickerPills: View {
    @Binding var date: Date
    var range: PartialRangeFrom<Date>?

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            // Date Pill
            ZStack {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .foregroundColor(DS.Colors.accent)
                    Text(formattedDate)
                        .foregroundColor(DS.Colors.textPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DS.Materials.platter)
                .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                .shadow(color: DS.Shadows.ambientColor, radius: 1, y: 1)
                
                if let range = range {
                    DatePicker("", selection: $date, in: range, displayedComponents: .date)
                        .labelsHidden()
                        .scaleEffect(3.0)
                        .opacity(0.011)
                } else {
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                        .scaleEffect(3.0)
                        .opacity(0.011)
                }
            }
            .clipped()
            
            // Time Pill
            ZStack {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .foregroundColor(.gray)
                    Text(formattedTime)
                        .foregroundColor(DS.Colors.textPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DS.Materials.platter)
                .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                .shadow(color: DS.Shadows.ambientColor, radius: 1, y: 1)

                if let range = range {
                    DatePicker("", selection: $date, in: range, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .scaleEffect(3.0)
                        .opacity(0.011)
                } else {
                    DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .scaleEffect(3.0)
                        .opacity(0.011)
                }
            }
            .clipped()
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
