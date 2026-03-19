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
    @State private var pomodoroLongBreak: Int = 15
    @State private var pomodoroLongBreakEnabled: Bool = false

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
        let workTotal = pomodoroWork * pomodoroRounds
        let shortBreakTotal = pomodoroBreak * (pomodoroRounds - 1)
        let longBreak = pomodoroLongBreakEnabled ? pomodoroLongBreak : 0
        return workTotal + shortBreakTotal + longBreak
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Repeat")
                .font(.headline)
                .foregroundColor(DS.Colors.textPrimary)

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
        .onChange(of: mode) { syncToBinding() }
        .onChange(of: interval) { syncToBinding() }
        .onChange(of: endChoice) { syncToBinding() }
        .onChange(of: endCount) { syncToBinding() }
        .onChange(of: endDate) { syncToBinding() }
        .onChange(of: selectedWeekdays) { syncToBinding() }
        .onChange(of: monthlyMode) { syncToBinding() }
        .onChange(of: pomodoroWork) { syncToBinding() }
        .onChange(of: pomodoroBreak) { syncToBinding() }
        .onChange(of: pomodoroRounds) { syncToBinding() }
        .onChange(of: pomodoroLongBreak) { syncToBinding() }
        .onChange(of: pomodoroLongBreakEnabled) { syncToBinding() }
        .onAppear { loadFromBinding() }
    }

    // MARK: - Mode Picker

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            Text("Never").tag(RepeatMode.none)
            Divider()
            Label("Pomodoro", systemImage: "timer").tag(RepeatMode.pomodoro)
            Divider()
            ForEach(RecurrenceFrequency.userVisible, id: \.self) { freq in
                Text("Every \(freq.label)").tag(RepeatMode.standard(freq))
            }
        }
        .pickerStyle(.menu)
        .frame(height: DS.Size.selectorHeight)
    }

    // MARK: - Pomodoro Controls

    private var pomodoroControls: some View {
        Group {
            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.md, verticalSpacing: DS.Spacing.sm) {
                // Work duration
                GridRow {
                    Label("Work: \(pomodoroWork) min", systemImage: "brain.head.profile")
                        .foregroundColor(.primary)
                        .gridColumnAlignment(.leading)
                    
                    Stepper("", value: $pomodoroWork, in: 1...90)
                        .labelsHidden()
                }

                // Rounds
                GridRow {
                    Label("Rounds: \(pomodoroRounds)", systemImage: "arrow.trianglehead.2.counterclockwise")
                        .foregroundColor(.primary)
                    
                    Stepper("", value: $pomodoroRounds, in: 1...12)
                        .labelsHidden()
                }

                // Break controls only when there are multiple rounds
                if pomodoroRounds > 1 {
                    GridRow {
                        Label("Break: \(pomodoroBreak) min", systemImage: "cup.and.saucer")
                            .foregroundColor(.primary)
                        
                        Stepper("", value: $pomodoroBreak, in: 1...30)
                            .labelsHidden()
                    }

                    GridRow {
                        Toggle(isOn: $pomodoroLongBreakEnabled) {
                            Label("Long break", systemImage: "moon.zzz")
                                .foregroundColor(.primary)
                        }
                        
                        Color.clear // Empty cell for alignment
                    }

                    if pomodoroLongBreakEnabled {
                        GridRow {
                            Label("Duration: \(pomodoroLongBreak) min", systemImage: "moon.zzz")
                                .foregroundColor(.primary)
                                .padding(.leading, DS.Spacing.lg) // Optional indent for hierarchy
                            
                            Stepper("", value: $pomodoroLongBreak, in: 5...60, step: 5)
                                .labelsHidden()
                        }
                    }
                }
            }
            .padding(.top, DS.Spacing.md)

            // Visual timeline
            pomodoroTimeline
                .padding(.vertical, DS.Spacing.md)
                .animation(DS.Animation.standard, value: pomodoroWork)
                .animation(DS.Animation.standard, value: pomodoroBreak)
                .animation(DS.Animation.standard, value: pomodoroRounds)
                .animation(DS.Animation.standard, value: pomodoroLongBreakEnabled)
                .animation(DS.Animation.standard, value: pomodoroLongBreak)

            // Total summary
            HStack {
                Label(
                    "Total: \(DS.formatMinutes(pomodoroTotalMinutes))",
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundColor(.secondary)

                Spacer()

                Link("Learn about Pomodoro combinations", destination: URL(string: "https://github.com/avpv/bubo/blob/HEAD/docs/Pomodoro.md")!)
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
    }

    // MARK: - Pomodoro Timeline Preview

    /// Build the list of timeline segments with their start times.
    private var pomodoroSegments: [(type: String, minutes: Int, startOffset: Int)] {
        var segments: [(type: String, minutes: Int, startOffset: Int)] = []
        var offset = 0
        for round in 0..<pomodoroRounds {
            segments.append((type: "work", minutes: pomodoroWork, startOffset: offset))
            offset += pomodoroWork
            if round < pomodoroRounds - 1 {
                segments.append((type: "break", minutes: pomodoroBreak, startOffset: offset))
                offset += pomodoroBreak
            }
        }
        if pomodoroLongBreakEnabled && pomodoroLongBreak > 0 {
            segments.append((type: "long", minutes: pomodoroLongBreak, startOffset: offset))
        }
        return segments
    }

    private var pomodoroTimeline: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            // Bar visualization
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let totalDuration = CGFloat(pomodoroTotalMinutes)
                HStack(spacing: 0) {
                    ForEach(Array(pomodoroSegments.enumerated()), id: \.offset) { _, segment in
                        let segWidth = totalWidth * CGFloat(segment.minutes) / totalDuration
                        let color: Color = segment.type == "work" ? .accentColor
                            : segment.type == "long" ? .indigo.opacity(0.5)
                            : .green.opacity(0.5)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(color)
                            .frame(width: max(segWidth - 1, 3))
                            .overlay {
                                if segWidth > 20 {
                                    Text("\(segment.minutes)")
                                        .font(.system(size: 9, weight: .medium, design: .rounded))
                                        .foregroundColor(.white)
                                }
                            }
                    }
                }
            }
            .frame(height: 20)
            .accessibilityElement()
            .accessibilityLabel(
                "Pomodoro timeline: \(pomodoroRounds) rounds of \(pomodoroWork) min work and \(pomodoroBreak) min break"
                + (pomodoroLongBreakEnabled ? ", then \(pomodoroLongBreak) min long break" : "")
            )

            // Session schedule with actual times
            pomodoroSchedule

            // Legend
            HStack(spacing: DS.Spacing.lg) {
                legendItem(color: Color.accentColor, label: "Work")
                legendItem(color: Color.green.opacity(0.5), label: "Break")
                if pomodoroLongBreakEnabled {
                    legendItem(color: Color.indigo.opacity(0.5), label: "Long")
                }
            }
        }
    }

    /// Shows the actual session schedule with real times based on event start.
    /// Collapses middle segments when there are too many to fit.
    private var pomodoroSchedule: some View {
        let segments = pomodoroSegments
        let maxVisible = 6

        return VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            if segments.count <= maxVisible {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    scheduleRow(segment)
                }
            } else {
                // Show first 2, ellipsis, last 2
                ForEach(Array(segments.prefix(2).enumerated()), id: \.offset) { _, segment in
                    scheduleRow(segment)
                }
                HStack(spacing: DS.Spacing.xs) {
                    Spacer().frame(width: DS.Spacing.lg)
                    Text("···  \(segments.count - 4) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                ForEach(Array(segments.suffix(2).enumerated()), id: \.offset) { idx, segment in
                    scheduleRow(segment)
                }
            }
        }
    }

    private func scheduleRow(_ segment: (type: String, minutes: Int, startOffset: Int)) -> some View {
        let start = eventStartDate.addingTimeInterval(TimeInterval(segment.startOffset * 60))
        let end = start.addingTimeInterval(TimeInterval(segment.minutes * 60))
        let icon = segment.type == "work" ? "brain.head.profile"
            : segment.type == "long" ? "moon.zzz"
            : "cup.and.saucer"
        let color: Color = segment.type == "work" ? .primary
            : segment.type == "long" ? .indigo
            : .green

        return HStack(spacing: DS.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(color)
                .frame(width: DS.Spacing.lg)
            Text("\(DS.timeFormatter.string(from: start))–\(DS.timeFormatter.string(from: end))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Circle().fill(color).frame(width: DS.Size.todayDotSize, height: DS.Size.todayDotSize)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: - Standard Recurrence Controls

    @ViewBuilder
    private func standardControls(_ freq: RecurrenceFrequency) -> some View {
        Color.clear.frame(height: DS.Spacing.xs) // Adds top spacing matching Pomodoro

        // Interval
        Stepper(
            "Every \(interval) \(interval == 1 ? freq.singularUnit : freq.pluralUnit)",
            value: $interval, in: 1...99
        )

        // Weekly: weekday chips
        if freq == .weekly {
            Color.clear.frame(height: 2)
            weekdayChips
        }

        // Monthly: mode picker
        if freq == .monthly {
            Color.clear.frame(height: 2)
            monthlyModePicker
        }

        Color.clear.frame(height: 4)

        // End condition
        Picker("Ends", selection: $endChoice) {
            ForEach(EndChoice.allCases, id: \.self) { c in
                Text(c.rawValue).tag(c)
            }
        }
        .pickerStyle(.menu)
        .frame(height: DS.Size.selectorHeight)

        switch endChoice {
        case .never:
            EmptyView()
        case .afterCount:
            Color.clear.frame(height: 2)
            Stepper("After \(endCount) occurrences", value: $endCount, in: 2...100)
        case .onDate:
            Color.clear.frame(height: 2)
            DatePicker("Until", selection: $endDate, in: eventStartDate..., displayedComponents: .date)
        }

        // Summary
        if let built = buildStandardRule(freq) {
            Color.clear.frame(height: 4)
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
                                : DS.Colors.badgeFill(.secondary)
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
        .frame(height: DS.Size.selectorHeight)
    }

    // MARK: - Build Rules

    private func buildPomodoroRule() -> RecurrenceRule {
        RecurrenceRule(
            frequency: .minutely,
            interval: pomodoroCycleMinutes,
            end: .afterCount(pomodoroRounds),
            pomodoroMode: true,
            pomodoroLongBreak: pomodoroLongBreakEnabled ? pomodoroLongBreak : 0
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

        // Detect Pomodoro: explicit flag
        if r.pomodoroMode {
            mode = .pomodoro
            if case .afterCount(let rounds) = r.end {
                pomodoroRounds = rounds
            }
            let workMin = Int(eventDuration)
            let cycleMin = r.interval
            pomodoroWork = max(workMin, 5)
            pomodoroBreak = max(cycleMin - workMin, 1)
            if r.pomodoroLongBreak > 0 {
                pomodoroLongBreakEnabled = true
                pomodoroLongBreak = r.pomodoroLongBreak
            }
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
