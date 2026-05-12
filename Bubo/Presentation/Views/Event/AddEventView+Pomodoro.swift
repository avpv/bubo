import SwiftUI
import BuboDomain

// MARK: - AddEventView: Pomodoro
//
// Pomodoro toggle, configuration section, timeline preview and
// recurrence-rule builder. Extracted from AddEventView.swift.

extension AddEventView {

    // MARK: - Pomodoro Toggle (mode switch)

    /// Binding that flips `selectedEventType` between `.standard` and
    /// `.pomodoro`. Lives outside the body so SwiftUI doesn't recompute
    /// it for every render. HIG: a Toggle is the platform-correct control
    /// for "this event runs as a Pomodoro session" (boolean state).
    var pomodoroBinding: Binding<Bool> {
        Binding(
            get: { selectedEventType == .pomodoro },
            set: { newValue in
                withAnimation(DS.Animation.motionAware(DS.Animation.standard, reduceMotion: reduceMotion)) {
                    selectedEventType = newValue ? .pomodoro : .standard
                }
            }
        )
    }

    var pomodoroToggleRow: some View {
        Toggle(isOn: pomodoroBinding) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "timer")
                    .font(DS.Typography.body(skin: skin))
                    .foregroundStyle(isPomodoroMode ? skinAccent : skin.resolvedTextSecondary)
                    .frame(width: DS.Size.iconLarge)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text("Run as Pomodoro")
                        .font(DS.Typography.body(skin: skin))
                        .foregroundStyle(skin.resolvedTextPrimary)
                    // Birman: the subtitle explains what will happen, without
                    // needing to know the word "Pomodoro" in advance.
                    Text("Split into focused work + break sessions")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityHint("Splits this event into work and break intervals")
    }

    // MARK: - Pomodoro Section

    var pomodoroSection: some View {
        // Birman: no sectionLabel("Pomodoro") here — the toggle row above
        // already says "Run as Pomodoro" with a timer icon. Three labels
        // for the same concept on one screen is two too many. The outer
        // VStack that used to host that label is also gone — its only
        // remaining child is the parameter stack below.
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.md, verticalSpacing: DS.Spacing.sm) {
                GridRow {
                    Label("Work: \(pomodoroWork)\u{00A0}min", systemImage: "brain.head.profile")
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .gridColumnAlignment(.leading)
                    Stepper("Work duration", value: $pomodoroWork, in: 1...90)
                        .labelsHidden()
                }

                GridRow {
                    Label("Rounds: \(pomodoroRounds)", systemImage: "arrow.trianglehead.2.counterclockwise")
                        .foregroundStyle(skin.resolvedTextPrimary)
                    Stepper("Number of rounds", value: $pomodoroRounds, in: 1...12)
                        .labelsHidden()
                }

                if pomodoroRounds > 1 {
                    GridRow {
                        Label("Break: \(pomodoroBreak)\u{00A0}min", systemImage: "cup.and.saucer")
                            .foregroundStyle(skin.resolvedTextPrimary)
                        Stepper("Break duration", value: $pomodoroBreak, in: 1...30)
                            .labelsHidden()
                    }

                    GridRow {
                        Toggle(isOn: $pomodoroLongBreakEnabled) {
                            Label("Long break", systemImage: "moon.zzz")
                                .foregroundStyle(skin.resolvedTextPrimary)
                        }
                        Color.clear
                    }

                    if pomodoroLongBreakEnabled {
                        GridRow {
                            Label("Duration: \(pomodoroLongBreak)\u{00A0}min", systemImage: "moon.zzz")
                                .foregroundStyle(skin.resolvedTextPrimary)
                                .padding(.leading, DS.Spacing.lg)
                            Stepper("Long break duration", value: $pomodoroLongBreak, in: 5...60, step: 5)
                                .labelsHidden()
                        }
                    }
                }
            }

            // Visual timeline
            pomodoroTimeline
                .padding(.vertical, DS.Spacing.md)
                .animation(skin.resolvedMicroAnimation, value: pomodoroWork)
                .animation(skin.resolvedMicroAnimation, value: pomodoroBreak)
                .animation(skin.resolvedMicroAnimation, value: pomodoroRounds)
                .animation(skin.resolvedMicroAnimation, value: pomodoroLongBreakEnabled)
                .animation(skin.resolvedMicroAnimation, value: pomodoroLongBreak)

            HStack {
                Label(
                    "Total: \(DS.formatMinutes(pomodoroTotalMinutes))",
                    systemImage: "clock"
                )
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)

                Spacer()

                Link("Learn about Pomodoro combinations", destination: URL(string: "https://github.com/avpv/bubo/blob/HEAD/docs/Pomodoro.md")!)
                    .font(.footnote)
                    .foregroundStyle(skin.accentColor)
                    .accessibilityHint("Opens in your web browser")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pomodoro Timeline Preview

    /// Build the list of timeline segments with their start times.
    var pomodoroSegments: [(type: String, minutes: Int, startOffset: Int)] {
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

    // MARK: - Segment Styling Helpers

    func segmentColor(for type: String) -> Color {
        switch type {
        case "work": skin.accentColor
        case "long": DS.Colors.info
        default: skin.resolvedSuccessColor
        }
    }

    func segmentIcon(for type: String) -> String {
        switch type {
        case "work": "brain.head.profile"
        case "long": "moon.zzz"
        default: "cup.and.saucer"
        }
    }

    func segmentLabel(for type: String) -> String {
        switch type {
        case "work": "Work"
        case "long": "Long break"
        default: "Break"
        }
    }

    // MARK: - Improved Timeline

    var pomodoroTimeline: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Legend row (above bar for context)
            HStack(spacing: DS.Spacing.md) {
                legendItem(color: skin.accentColor, icon: "brain.head.profile", label: "Work")
                legendItem(color: skin.resolvedSuccessColor, icon: "cup.and.saucer", label: "Break")
                if pomodoroLongBreakEnabled {
                    legendItem(color: DS.Colors.info, icon: "moon.zzz", label: "Long break")
                }
                Spacer()
                // Work/break ratio
                let totalWork = pomodoroWork * pomodoroRounds
                let totalBreak = pomodoroTotalMinutes - totalWork
                if totalBreak > 0 {
                    Text("\(totalWork):\(totalBreak)")
                        .font(.system(.footnote, design: .monospaced, weight: .medium))
                        .foregroundStyle(skin.resolvedTextTertiary)
                    + Text(" work:rest")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
            }

            // Bar visualization
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let totalDuration = CGFloat(pomodoroTotalMinutes)
                HStack(spacing: 1.5) {
                    ForEach(Array(pomodoroSegments.enumerated()), id: \.offset) { idx, segment in
                        let rawWidth = totalWidth * CGFloat(segment.minutes) / totalDuration
                        let segWidth = max(rawWidth - 1.5, 4)
                        let color = segmentColor(for: segment.type)
                        let isFirst = idx == 0
                        let isLast = idx == pomodoroSegments.count - 1

                        RoundedRectangle(
                            cornerRadius: (isFirst || isLast) ? max(DS.Size.cornerRadius - 3, 3) : max(DS.Size.cornerRadius - 5, 2),
                            style: .continuous
                        )
                        .fill(
                            LinearGradient(
                                colors: [color, color.opacity(DS.Opacity.accentMuted)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: segWidth)
                        .overlay {
                            if segWidth > 30 {
                                Text("\(segment.minutes)\u{00A0}m")
                                    .font(.system(.footnote, design: skin.resolvedFontDesign, weight: .semibold))
                                    .foregroundStyle(DS.contrastingForeground(for: color))
                            }
                        }
                    }
                }
            }
            .frame(height: DS.Size.controlHeight)
            .accessibilityElement()
            .accessibilityLabel(
                "Pomodoro timeline: \(pomodoroRounds) rounds of \(pomodoroWork)\u{00A0}min work and \(pomodoroBreak)\u{00A0}min break"
                + (pomodoroLongBreakEnabled ? ", then \(pomodoroLongBreak)\u{00A0}min long break" : "")
            )

            // Session schedule
            pomodoroSchedule
        }
    }

    /// Shows the actual session schedule with real times based on event start.
    /// Collapses middle segments when there are too many to fit.
    var pomodoroSchedule: some View {
        let segments = pomodoroSegments
        let maxVisible = 6

        return VStack(alignment: .leading, spacing: 0) {
            if segments.count <= maxVisible {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                    scheduleRow(segment, index: idx, total: segments.count)
                }
            } else {
                ForEach(Array(segments.prefix(2).enumerated()), id: \.offset) { idx, segment in
                    scheduleRow(segment, index: idx, total: segments.count)
                }
                HStack(spacing: DS.Spacing.sm) {
                    // Connecting line centered in the same 12pt column as dots
                    Rectangle()
                        .fill(skin.resolvedTextSecondary.opacity(DS.Opacity.subtleBorder))
                        .frame(width: 1.5, height: 16)
                        .frame(width: 12)
                    Text("\(segments.count - 4) more")
                        .font(.system(.footnote, design: skin.resolvedFontDesign))
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
                ForEach(Array(segments.suffix(2).enumerated()), id: \.offset) { idx, segment in
                    scheduleRow(segment, index: segments.count - 2 + idx, total: segments.count)
                }
            }
        }
    }

    func scheduleRow(
        _ segment: (type: String, minutes: Int, startOffset: Int),
        index: Int,
        total: Int
    ) -> some View {
        let start = date.addingTimeInterval(TimeInterval(segment.startOffset * 60))
        let end = start.addingTimeInterval(TimeInterval(segment.minutes * 60))
        let color = segmentColor(for: segment.type)
        let icon = segmentIcon(for: segment.type)
        let label = segmentLabel(for: segment.type)
        let isLast = index == total - 1

        return HStack(alignment: .top, spacing: DS.Spacing.sm) {
            // Left: icon dot with connecting line
            ZStack(alignment: .top) {
                if !isLast {
                    Rectangle()
                        .fill(color.opacity(DS.Opacity.strongFill))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(DS.contrastingForeground(for: color))
                    }
            }
            .frame(width: 12)

            // Right: time and label
            VStack(alignment: .leading, spacing: 1) {
                Text("\(DS.timeFormatter.string(from: start)) – \(DS.timeFormatter.string(from: end))")
                    .font(.system(.footnote, design: .monospaced, weight: .medium))
                    .foregroundStyle(skin.resolvedTextPrimary)
                Text("\(label) · \(segment.minutes)\u{00A0}min")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }
            .padding(.bottom, isLast ? 0 : DS.Spacing.xs)
        }
    }

    func legendItem(color: Color, icon: String, label: String) -> some View {
        HStack(spacing: DS.Spacing.xxs) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(color)
            Text(label)
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
        }
    }

    func buildPomodoroRule() -> RecurrenceRule {
        RecurrenceRule(
            frequency: .minutely,
            interval: pomodoroCycleMinutes,
            end: .afterCount(pomodoroRounds),
            pomodoroMode: true,
            pomodoroLongBreak: pomodoroLongBreakEnabled ? pomodoroLongBreak : 0
        )
    }

}
