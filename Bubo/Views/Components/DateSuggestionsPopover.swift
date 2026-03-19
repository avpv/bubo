import SwiftUI

struct DateSuggestionsPopover: View {
    @Binding var date: Date
    @Binding var isPresented: Bool
    var range: PartialRangeFrom<Date>?
    
    @State private var showCustomCalendar = false
    
    var body: some View {
        VStack(spacing: 0) {
            if showCustomCalendar {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    HStack {
                        Button(action: { showCustomCalendar = false }) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(DS.Colors.accent)
                        
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                    
                    if let range = range {
                        DatePicker("", selection: Binding(get: { date }, set: { newDate in
                            date = newDate
                            isPresented = false
                        }), in: range, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding(.horizontal)
                        .padding(.bottom)
                    } else {
                        DatePicker("", selection: Binding(get: { date }, set: { newDate in
                            date = newDate
                            isPresented = false
                        }), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding(.horizontal)
                        .padding(.bottom)
                    }
                }
                .fixedSize()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Suggestions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    
                    ForEach(0..<7) { offset in
                        if let d = Calendar.current.date(byAdding: .day, value: offset, to: Date()) {
                            suggestionRow(
                                title: titleForDate(d, offset: offset),
                                subtitle: formatted(d),
                                action: { selectDate(d) }
                            )
                        }
                    }
                    
                    Divider().padding(.vertical, 4)
                    
                    Button(action: { showCustomCalendar = true }) {
                        HStack(spacing: 12) {
                            Image(systemName: "calendar")
                                .foregroundColor(.secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Custom...")
                                    .foregroundColor(DS.Colors.textPrimary)
                                Text("Use the calendar to pick a date")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
                .frame(width: 240)
            }
        }
    }
    
    private func suggestionRow(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .foregroundColor(.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter.string(from: date)
    }
    
    private func titleForDate(_ date: Date, offset: Int) -> String {
        if offset == 0 { return "Today" }
        if offset == 1 { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
    
    private func selectDate(_ newDate: Date) {
        let cal = Calendar.current
        let timeComps = cal.dateComponents([.hour, .minute, .second], from: date)
        let dateComps = cal.dateComponents([.year, .month, .day], from: newDate)
        
        var finalComps = DateComponents()
        finalComps.year = dateComps.year
        finalComps.month = dateComps.month
        finalComps.day = dateComps.day
        finalComps.hour = timeComps.hour
        finalComps.minute = timeComps.minute
        finalComps.second = timeComps.second
        
        if let finalDate = cal.date(from: finalComps) {
            date = finalDate
        }
        isPresented = false
    }
}
