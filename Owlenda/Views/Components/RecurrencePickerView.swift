import SwiftUI

/// Reusable recurrence configuration picker, inspired by Apple Calendar.
/// Supports both standard calendar recurrence and Pomodoro Technique mode.
struct RecurrencePickerView: View {
    @Binding var rule: RecurrenceRule?
    @Binding var eventDuration: Double
    let eventStartDate: Date

    // MARK: - Repeat mode (top-level choice)

    /// Top-level mode: none, pomodoro, or a standard calendar frequency.
    private enum RepeatMode: Hashable {
        case none
        case pomodoro
        case standard(RecurrenceFrequency)
    }

    @State private var mode: RepeatMode = .none

    // MARK: - Standard recurrence state

    @State private var interval: Int = 1
    @State private var endChoice: EndChoice = .never
    @State private var endCount: Int = 10
    @State private var endDate: Date = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var selectedWeekdays: Set<Weekday> = []
    @State private var monthlyMode: MonthlyModeChoice = .dayOfMonth

    // MARK: - Pomodoro state

    @State private var pomodoroWork: Int = 25
    @State private var pomodoroBreak: Int = 5
    @State private var pomodoroRounds: Int = 4

    // MARK: - Enums

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

    // MARK: - Computed helpers

    private var startDayOfMonth: Int {
        Calendar.current.component(.day, from: eventStartDate)
    }

    private var startWeekdayOrdinal: Int {
        Calendar.current.component(.weekdayOrdinal, from: eventStartDate)
    }

    private var startWeekday: Weekday? {
        let wd = Calendar.current.component(.weekday, from: eventStartDate)
        return Weekday.from(calendarWeekday: wd)
    }

    private var pomodoroCycleMinutes: Int {
        pomodoroWork + pomodoroBreak
    }

    private var pomodoroTotalMinutes: Int {
        pomodoroWork * pomodoroRounds + pomodoroBreak * (pomodoroRounds - 1)
    }

    // MARK: - Body

    var body: some View {
        Section("Repeat") {
            modePicker

            switch mode {
            case .none:
                EmptyView()
            case .pomodoro:
                pomodoroControls
            case .standard(let freq):
                standardControls(freq)
            }
        }
        .onChange(of: mode) { _ in syncToBinding() }
        .onChange(of: interval) { _ in syncToBinding() }
        .onChange(of: endChoice) { _ in syncToBinding() }
        .onChange(of: endCount) { _ in syncToBinding() }
        .onChange(of: endDate) { _ in syncToBinding() }
        .onChange(of: selectedWeekdays) { _ in syncToBinding() }
        .onChange(of: monthlyMode) { _ in syncToBinding() }
        .onChange(of: pomodoroWork) { _ in syncToBinding() }
        .onChange(of: pomodoroBreak) { _ in syncToBinding() }
        .onChange(of: pomodoroRounds) { _ in syncToBinding() }
        .onAppear { loadFromBinding() }
    }

    // MARK: - Mode Picker

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            Text("Never").tag(RepeatMode.none)
            Label("Pomodoro", systemImage: "timer").tag(RepeatMode.pomodoro)
            Divider()
            ForEach(RecurrenceFrequency.userVisible, id: \.self) { freq in
                Text("Every \(freq.label)").tag(RepeatMode.standard(freq))
            }
        }
        .pickerStyle(.menu)
    }

    // MARK: - Pomodoro Controls

    private var pomodoroControls: some View {
        Group {
            // Work duration
            Stepper(value: $pomodoroWork, in: 5...90, step: 5) {
                Label("Work: \(pomodoroWork) min", systemImage: "brain.head.profile")
                    .foregroundColor(.primary)
            }

            // Break duration
            Stepper(value: $pomodoroBreak, in: 1...30) {
                Label("Break: \(pomodoroBreak) min", systemImage: "cup.and.saucer")
                    .foregroundColor(.primary)
            }

            // Rounds
            Stepper(value: $pomodoroRounds, in: 1...12) {
                Label("Rounds: \(pomodoroRounds)", systemImage: "arrow.trianglehead.2.counterclockwise")
                    .foregroundColor(.primary)
            }

            // Visual timeline
            pomodoroTimeline

            // Total summary
            Label(
                "Total: \(DS.formatMinutes(pomodoroTotalMinutes))",
                systemImage: "clock"
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    // MARK: - Pomodoro Timeline Preview

    private var pomodoroTimeline: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let totalDuration = CGFloat(pomodoroTotalMinutes)
                HStack(spacing: 0) {
                    ForEach(0..<pomodoroRounds, id: \.self) { round in
                        let workWidth = totalWidth * CGFloat(pomodoroWork) / totalDuration
                        let breakWidth = round < pomodoroRounds - 1
                            ? totalWidth * CGFloat(pomodoroBreak) / totalDuration
                            : 0

                        // Work block
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor)
                            .frame(width: max(workWidth - 1, 4))
                            .overlay {
                                if workWidth > 20 {
                                    Text("\(pomodoroWork)")
                                        .font(.system(size: 9, weight: .medium, design: .rounded))
                                        .foregroundColor(.white)
                                }
                            }

                        if round < pomodoroRounds - 1 {
                            // Break block
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.green.opacity(0.5))
                                .frame(width: max(breakWidth - 1, 3))
                        }
                    }
                }
            }
            .frame(height: 20)
            .accessibilityElement()
            .accessibilityLabel("Pomodoro timeline: \(pomodoroRounds) rounds of \(pomodoroWork) min work and \(pomodoroBreak) min break")

            // Legend
            HStack(spacing: DS.Spacing.lg) {
                HStack(spacing: DS.Spacing.xs) {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    Text("Work").font(.caption2).foregroundColor(.secondary)
                }
                HStack(spacing: DS.Spacing.xs) {
                    Circle().fill(Color.green.opacity(0.5)).frame(width: 6, height: 6)
                    Text("Break").font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Standard Recurrence Controls

    @ViewBuilder
    private func standardControls(_ freq: RecurrenceFrequency) -> some View {
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
        if let built = buildStandardRule(freq) {
            Label(built.displayText, systemImage: "repeat")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Weekly Weekday Chips

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

    // MARK: - Build Rules

    private func buildPomodoroRule() -> RecurrenceRule {
        RecurrenceRule(
            frequency: .minutely,
            interval: pomodoroCycleMinutes,
            end: .afterCount(pomodoroRounds)
        )
    }

    private func buildStandardRule(_ freq: RecurrenceFrequency) -> RecurrenceRule? {
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

    // MARK: - Sync / Load

    private func syncToBinding() {
        switch mode {
        case .none:
            rule = nil
        case .pomodoro:
            rule = buildPomodoroRule()
            eventDuration = Double(pomodoroWork)
        case .standard(let freq):
            if freq != .weekly { selectedWeekdays.removeAll() }
            rule = buildStandardRule(freq)
        }
    }

    private func loadFromBinding() {
        guard let r = rule else {
            mode = .none
            return
        }

        // Detect Pomodoro: minutely frequency with afterCount end
        if r.frequency == .minutely, case .afterCount(let rounds) = r.end {
            mode = .pomodoro
            pomodoroRounds = rounds
            let workMin = Int(eventDuration)
            let cycleMin = r.interval
            pomodoroWork = max(workMin, 5)
            pomodoroBreak = max(cycleMin - workMin, 1)
            return
        }

        // Standard recurrence
        mode = .standard(r.frequency)
        interval = r.interval
        selectedWeekdays = r.weekdays
        switch r.end {
        case .never: endChoice = .never
        case .afterCount(let c): endChoice = .afterCount; endCount = c
        case .untilDate(let d): endChoice = .onDate; endDate = d
        }
        if let m = r.monthlyMode {
            switch m {
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
