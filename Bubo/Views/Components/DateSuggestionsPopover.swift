import SwiftUI

struct DateSuggestionsPopover: View {
    @Environment(\.activeSkin) private var skin
    @Binding var date: Date
    @Binding var isPresented: Bool
    var range: PartialRangeFrom<Date>?

    @State private var showCustomCalendar = false

    var body: some View {
        VStack(spacing: 0) {
            if showCustomCalendar {
                VStack(spacing: 0) {
                    HStack {
                        Button(action: { showCustomCalendar = false }) {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        Spacer()
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.md)

                    SkinSeparator()
                        .padding(.bottom, DS.Spacing.sm)

                    if let range = range {
                        DatePicker("Select date", selection: Binding(get: { date }, set: { newDate in
                            date = newDate
                            isPresented = false
                        }), in: range, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(.horizontal)
                        .padding(.bottom)
                    } else {
                        DatePicker("Select date", selection: Binding(get: { date }, set: { newDate in
                            date = newDate
                            isPresented = false
                        }), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(.horizontal)
                        .padding(.bottom)
                    }
                }
                .fixedSize()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Suggestions")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.top, DS.Spacing.md)
                        .padding(.bottom, DS.Spacing.sm)

                    ForEach(0..<7) { offset in
                        if let d = Calendar.current.date(byAdding: .day, value: offset, to: Date()) {
                            suggestionRow(
                                title: titleForDate(d, offset: offset),
                                subtitle: formatted(d),
                                action: { selectDate(d) }
                            )
                        }
                    }

                    SkinSeparator().padding(.vertical, DS.Spacing.xs)

                    Button(action: { showCustomCalendar = true }) {
                        HStack(spacing: DS.Spacing.md) {
                            Image(systemName: "calendar")
                                .foregroundStyle(skin.resolvedTextSecondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                Text("Custom\u{2026}")
                                    .foregroundStyle(skin.resolvedTextPrimary)
                                Text("Use the calendar to pick a date")
                                    .font(.caption)
                                    .foregroundStyle(skin.resolvedTextSecondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.sm)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, DS.Spacing.sm)
                }
                .frame(width: DS.Popover.dateSuggestionsWidth)
            }
        }
    }

    private func suggestionRow(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: "calendar")
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(title)
                        .foregroundStyle(skin.resolvedTextPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }

    private func titleForDate(_ date: Date, offset: Int) -> String {
        if offset == 0 { return "Today" }
        if offset == 1 { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
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
