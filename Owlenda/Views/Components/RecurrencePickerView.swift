import SwiftUI

/// Reusable recurrence configuration picker, inspired by Apple Calendar.
struct RecurrencePickerView: View {
    @Binding var rule: RecurrenceRule?
    let eventStartDate: Date

    @State private var frequency: RecurrenceFrequency? = nil
    @State private var interval: Int = 1
    @State private var endChoice: EndChoice = .never
    @State private var endCount: Int = 10
    @State private var endDate: Date = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var selectedWeekdays: Set<Weekday> = []
    @State private var monthlyMode: MonthlyModeChoice = .dayOfMonth

    /// Pomodoro Technique presets
    private struct PomodoroPreset: Identifiable {
        let id: String
        let name: String
        let intervalMinutes: Int
        let rounds: Int
        var description: String {
            "\(intervalMinutes) min × \(rounds)"
        }
    }

    private let pomodoroPresets: [PomodoroPreset] = [
        PomodoroPreset(id: "classic", name: "Classic", intervalMinutes: 25, rounds: 4),
        PomodoroPreset(id: "short", name: "Short", intervalMinutes: 15, rounds: 4),
        PomodoroPreset(id: "long", name: "Long", intervalMinutes: 50, rounds: 3),
    ]

    private enum EndChoice: String, CaseIterable {
        case never = "Never"
        case afterCount = "After"
        case onDate = "On date"
    }

    private enum MonthlyModeChoice: String, CaseIterable {
        case dayOfMonth = "Day of month"
        case weekdayPosition = "Weekday position"
        case lastWeekday = "Last weekday"
    }

    /// Computed day of month from event start date.
    private var startDayOfMonth: Int {
        Calendar.current.component(.day, from: eventStartDate)
    }

    /// Computed weekday ordinal from event start date (e.g. "2nd Tuesday").
    private var startWeekdayOrdinal: Int {
        Calendar.current.component(.weekdayOrdinal, from: eventStartDate)
    }

    private var startWeekday: Weekday? {
        let wd = Calendar.current.component(.weekday, from: eventStartDate)
        return Weekday.from(calendarWeekday: wd)
    }

    var body: some View {
        Section("Repeat") {
            Picker("Frequency", selection: $frequency) {
                Text("Never").tag(RecurrenceFrequency?.none)
                ForEach(RecurrenceFrequency.userVisible, id: \.self) { freq in
                    Text("Every \(freq.label)").tag(Optional(freq))
                }
            }
            .pickerStyle(.menu)

            // Pomodoro quick presets (shown when no frequency is selected or minutely is selected)
            if frequency == nil || frequency == .minutely {
                HStack(spacing: DS.Spacing.sm) {
                    ForEach(pomodoroPresets) { preset in
                        Button {
                            applyPomodoroPreset(preset)
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "timer")
                                    .font(.caption)
                                Text(preset.name)
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                Text(preset.description)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DS.Spacing.sm)
                            .background(
                                isPomodoroPresetActive(preset)
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.secondary.opacity(0.08)
                            )
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        isPomodoroPresetActive(preset)
                                            ? Color.accentColor
                                            : Color.clear,
                                        lineWidth: 1.5
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let freq = frequency {
                // Interval
                Stepper(
                    "Every \(interval) \(interval == 1 ? freq.singularUnit : freq.pluralUnit)",
                    value: $interval, in: 1...99
                )

                // Weekly: weekday chips
                if freq == .weekly {
                    weekdayChips
                }

                // Monthly: mode picker
                if freq == .monthly {
                    monthlyModePicker
                }

                // End condition
                Picker("Ends", selection: $endChoice) {
                    ForEach(EndChoice.allCases, id: \.self) { c in
                        Text(c.rawValue).tag(c)
                    }
                }
                .pickerStyle(.menu)

                switch endChoice {
                case .never:
                    EmptyView()
                case .afterCount:
                    Stepper("After \(endCount) occurrences", value: $endCount, in: 2...100)
                case .onDate:
                    DatePicker("Until", selection: $endDate, in: eventStartDate..., displayedComponents: .date)
                }

                // Summary
                if let built = buildRule() {
                    Label(built.displayText, systemImage: "repeat")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onChange(of: frequency) { newFreq in
            if newFreq != .weekly { selectedWeekdays.removeAll() }
            syncToBinding()
        }
        .onChange(of: interval) { _ in syncToBinding() }
        .onChange(of: endChoice) { _ in syncToBinding() }
        .onChange(of: endCount) { _ in syncToBinding() }
        .onChange(of: endDate) { _ in syncToBinding() }
        .onChange(of: selectedWeekdays) { _ in syncToBinding() }
        .onChange(of: monthlyMode) { _ in syncToBinding() }
        .onAppear { loadFromBinding() }
    }

    // MARK: - Weekly Weekday Chips (adaptive layout)

    private var weekdayChips: some View {
        FlowLayout(spacing: DS.Spacing.xs) {
            ForEach(Weekday.allCases, id: \.self) { day in
                Button {
                    if selectedWeekdays.contains(day) {
                        selectedWeekdays.remove(day)
                    } else {
                        selectedWeekdays.insert(day)
                    }
                } label: {
                    Text(day.shortName)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xs)
                        .background(
                            selectedWeekdays.contains(day)
                                ? Color.accentColor
                                : Color.secondary.opacity(0.12)
                        )
                        .foregroundColor(selectedWeekdays.contains(day) ? .white : .primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.fullName)
                .accessibilityAddTraits(selectedWeekdays.contains(day) ? .isSelected : [])
            }
        }
    }

    // MARK: - Monthly Mode Picker

    private var monthlyModePicker: some View {
        Picker("On", selection: $monthlyMode) {
            Text("On day \(startDayOfMonth)").tag(MonthlyModeChoice.dayOfMonth)
            if let wd = startWeekday {
                Text("On the \(DS.formatOrdinal(startWeekdayOrdinal)) \(wd.shortName)")
                    .tag(MonthlyModeChoice.weekdayPosition)
                Text("On the last \(wd.shortName)")
                    .tag(MonthlyModeChoice.lastWeekday)
            }
        }
        .pickerStyle(.menu)
    }

    // MARK: - Pomodoro Helpers

    private func applyPomodoroPreset(_ preset: PomodoroPreset) {
        frequency = .minutely
        interval = preset.intervalMinutes
        endChoice = .afterCount
        endCount = preset.rounds
        syncToBinding()
    }

    private func isPomodoroPresetActive(_ preset: PomodoroPreset) -> Bool {
        frequency == .minutely
            && interval == preset.intervalMinutes
            && endChoice == .afterCount
            && endCount == preset.rounds
    }

    // MARK: - Build / Sync

    private func buildRule() -> RecurrenceRule? {
        guard let freq = frequency else { return nil }
        let end: RecurrenceEnd
        switch endChoice {
        case .never: end = .never
        case .afterCount: end = .afterCount(endCount)
        case .onDate: end = .untilDate(endDate)
        }
        let monthly: MonthlyMode?
        if freq == .monthly {
            switch monthlyMode {
            case .dayOfMonth:
                monthly = .dayOfMonth(startDayOfMonth)
            case .weekdayPosition:
                if let wd = startWeekday {
                    monthly = .weekdayPosition(ordinal: startWeekdayOrdinal, weekday: wd)
                } else {
                    monthly = .dayOfMonth(startDayOfMonth)
                }
            case .lastWeekday:
                if let wd = startWeekday {
                    monthly = .weekdayPosition(ordinal: -1, weekday: wd)
                } else {
                    monthly = .dayOfMonth(startDayOfMonth)
                }
            }
        } else {
            monthly = nil
        }
        return RecurrenceRule(
            frequency: freq,
            interval: interval,
            end: end,
            weekdays: freq == .weekly ? selectedWeekdays : [],
            monthlyMode: monthly
        )
    }

    private func syncToBinding() {
        rule = buildRule()
    }

    private func loadFromBinding() {
        guard let r = rule else { return }
        frequency = r.frequency
        interval = r.interval
        selectedWeekdays = r.weekdays
        switch r.end {
        case .never: endChoice = .never
        case .afterCount(let c): endChoice = .afterCount; endCount = c
        case .untilDate(let d): endChoice = .onDate; endDate = d
        }
        if let mode = r.monthlyMode {
            switch mode {
            case .dayOfMonth: monthlyMode = .dayOfMonth
            case .weekdayPosition(let ordinal, _):
                monthlyMode = ordinal < 0 ? .lastWeekday : .weekdayPosition
            }
        }
    }
}

// MARK: - Adaptive Flow Layout

/// Simple flow layout that wraps children to the next line when they exceed available width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight + (i > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}
