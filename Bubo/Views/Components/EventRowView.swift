import SwiftUI

struct EventRowView: View {
    let event: CalendarEvent
    let reminderService: ReminderService
    var onEdit: ((CalendarEvent) -> Void)? = nil
    var onDelete: ((CalendarEvent) -> Void)? = nil
    var onDeleteOccurrence: ((CalendarEvent) -> Void)? = nil
    var onDeleteSeries: ((CalendarEvent) -> Void)? = nil
    var onTap: ((CalendarEvent) -> Void)? = nil

    // Task actions
    var onCompleteTask: ((CalendarEvent) -> Void)? = nil

    // Optimizer context menu actions
    var onFindBetterTime: ((CalendarEvent) -> Void)? = nil
    var onSplitTask: ((CalendarEvent) -> Void)? = nil
    var onProtectBlock: ((CalendarEvent) -> Void)? = nil
    var onAddPrep: ((CalendarEvent) -> Void)? = nil

    @State private var isHovered = false
    @State private var isDisintegrating = false
    @State private var pendingDeleteAction: (() -> Void)?
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.activeSkin) private var skin

    private var isLocal: Bool {
        event.isLocalEvent
    }

    var body: some View {
        // HIG: Use TimelineView for time-based UI updates
        TimelineView(.periodic(from: .now, by: 1)) { context in
        let now = context.date
        HStack(alignment: .center, spacing: 0) {
            // Urgency accent bar with glow for imminent events
            urgencyBar

            // Time indicator
            timeColumn(now)

            // Event details
            eventDetails

            Spacer(minLength: DS.Spacing.md)

            // Actions on hover — slide in from right
            if isHovered {
                hoverActions
            }
        }
        .frame(minHeight: DS.Size.eventRowMinHeight)
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.sm)
        .background(
            ZStack(alignment: .leading) {
                SkinPlatterBackground(skin: skin)

                if eventProgress(now) > 0 {
                    GeometryReader { geo in
                        let fillWidth = max(geo.size.width * eventProgress(now), DS.Size.cornerRadius * 2)
                        let baseColor = skin.isClassic ? DS.Colors.accent : skin.accentColor
                        let fillOpacity = contrast == .increased ? DS.Opacity.strongFill : DS.Opacity.mediumFill
                        
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        baseColor.opacity(fillOpacity * 0.5),
                                        baseColor.opacity(fillOpacity * 1.5)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: fillWidth)
                            // Glowing leading edge
                            .overlay(
                                Rectangle()
                                    .fill(baseColor.opacity(0.8))
                                    .frame(width: 2)
                                    .shadow(color: baseColor, radius: 4, x: 0, y: 0)
                                    .blendMode(.plusLighter),
                                alignment: .trailing
                            )
                    }
                }

                Rectangle()
                    .fill(isHovered ? skin.resolvedHoverFill : Color.clear)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(skin.platterBorderOpacity * 1.5),
                            .white.opacity(skin.platterBorderOpacity * 0.1),
                            .clear,
                            .white.opacity(skin.platterBorderOpacity * 0.4)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: DS.Border.thin
                )
                .blendMode(contrast == .increased ? .normal : .plusLighter)
        )
        .shadow(
            color: isHovered ? skin.resolvedHoverShadowColor : skin.resolvedShadowColor,
            radius: isHovered ? skin.hoverShadowRadius : skin.shadowRadius,
            y: isHovered ? skin.hoverShadowY : skin.shadowY
        )
        // Hover scale — slightly more pronounced for tactile feel
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            onTap?(event)
        }
        .onHover { hovering in
            withAnimation(skin.resolvedMicroAnimation) {
                isHovered = hovering
            }
            if hovering { Haptics.tap() }
        }
        // HIG: Support keyboard navigation — focusable rows, Enter to open
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(isFocused ? skin.accentColor.opacity(DS.Opacity.overlayDark) : Color.clear, lineWidth: DS.Size.focusRingWidth)
                .shadow(color: isFocused ? skin.accentColor.opacity(0.4) : .clear, radius: 4, x: 0, y: 0)
        )
        .animation(skin.resolvedMicroAnimation, value: isFocused)
        .onKeyPress(.return) {
            Haptics.tap()
            onTap?(event)
            return .handled
        }
        // Scroll-aware transition: fade/scale as items enter/exit viewport
        .eventScrollTransition()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title)\(event.isRecurring ? ", recurring" : ""), \(event.formattedTimeRange)\(event.location.map { ", \($0)" } ?? "")")
        .accessibilityHint("Press Enter to view details. Right-click to set reminder.")
        .accessibilityAddTraits(.isButton)
        .onChange(of: now) {
            // Detect event end and trigger disintegration
            if !event.isUpcoming && !isDisintegrating && !reminderService.disintegratingEventIDs.contains(event.id) {
                reminderService.beginDisintegration(for: event.id)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    isDisintegrating = true
                }
            }
        }
        .disintegrate(when: isDisintegrating) {
            if let action = pendingDeleteAction {
                action()
                pendingDeleteAction = nil
            } else {
                withAnimation(DS.Animation.smoothSpring) {
                    reminderService.completeDisintegration(for: event.id)
                }
            }
        }
        .contextMenu {
            Section("Set Reminder") {
                reminderMenuItems
            }

            if isLocal {
                Divider()

                // Task actions
                if event.isTask, event.taskStatus != .done, let onCompleteTask {
                    Button {
                        Haptics.impact()
                        onCompleteTask(event)
                    } label: {
                        Label("Complete Task", systemImage: "checkmark.circle.fill")
                    }
                }

                // Optimizer actions
                if let onFindBetterTime {
                    Button {
                        onFindBetterTime(event)
                    } label: {
                        Label("Find Better Time", systemImage: "wand.and.stars")
                    }
                }

                if event.duration > 2 * 3600, let onSplitTask {
                    Button {
                        onSplitTask(event)
                    } label: {
                        Label("Split into Sessions", systemImage: "scissors")
                    }
                }

                if (event.eventType == .pomodoro || event.title.localizedCaseInsensitiveContains("focus")),
                   let onProtectBlock {
                    Button {
                        onProtectBlock(event)
                    } label: {
                        Label("Protect This Block", systemImage: "shield")
                    }
                }

                if event.meetingLink != nil || event.calendarName != nil, let onAddPrep {
                    Button {
                        onAddPrep(event)
                    } label: {
                        Label("Add Prep Time", systemImage: "note.text")
                    }
                }

                Divider()
                Button("Edit") { onEdit?(event) }
                if event.isRecurring {
                    Menu("Delete") {
                        Button("Delete This Event Only", role: .destructive) { triggerDeleteWithDisintegration { onDeleteOccurrence?(event) } }
                        Button("Delete All Events", role: .destructive) { triggerDeleteWithDisintegration { onDeleteSeries?(event) } }
                    }
                } else {
                    Button("Delete", role: .destructive) { triggerDeleteWithDisintegration { onDelete?(event) } }
                }
            }
        }
        } // TimelineView
    }

    // MARK: - Urgency Bar

    private var accentBarColor: Color {
        event.colorTag?.color ?? (skin.isClassic ? DS.defaultEventColor : skin.accentColor)
    }

    private var urgencyBar: some View {
        Capsule()
            .fill(accentBarColor)
            .frame(width: DS.Size.accentBarWidth, height: DS.Size.accentBarHeight)
            .padding(.trailing, DS.Spacing.md)
            .shadow(
                color: accentBarColor.opacity(event.isUpcoming ? 0.6 : skin.shadowOpacity * 4),
                radius: event.isUpcoming ? 4 : skin.shadowRadius * 0.5
            )
    }

    // MARK: - Time Column

    private func timeColumn(_ now: Date) -> some View {
        VStack(spacing: DS.Spacing.xxs) {
            HStack(spacing: 2) {
                Text(event.formattedTime)
                    .font(.system(.caption, design: skin.resolvedFontDesign, weight: .bold))
                    .foregroundStyle(skin.resolvedTextPrimary)
                Text("–")
                    .font(.system(.caption, design: skin.resolvedFontDesign, weight: .bold))
                    .foregroundStyle(skin.resolvedTextSecondary)
                Text(event.formattedEndTime)
                    .font(.system(.caption, design: skin.resolvedFontDesign, weight: .regular))
                    .foregroundStyle(skin.resolvedTextSecondary)
            }

            Text(timeUntilText(now))
                .font(.system(.caption2, design: skin.resolvedFontDesign, weight: .semibold))
                .foregroundStyle(skin.isClassic ? skin.resolvedTextSecondary : skin.accentColor) // Highlight countdown
                .contentTransition(.numericText())
        }
        .frame(width: DS.Size.timeColumnWidth)
        .padding(.trailing, DS.Spacing.xs)
    }

    // MARK: - Event Details

    private var eventDetails: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xs) {
                Text(event.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .truncationMode(.tail)

                if let segment = event.pomodoroSegment {
                    Image(systemName: segment.iconName)
                        .font(.system(size: DS.Size.iconSmall, weight: .medium))
                        .foregroundStyle(pomodoroSegmentColor(segment))
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityLabel(segment.label)
                }
            }

            HStack(spacing: DS.Spacing.md) {
                if event.meetingLink != nil, let serviceName = event.meetingServiceName {
                    Label(serviceName, systemImage: "video.fill")
                        .font(.caption2)
                        .foregroundStyle(skin.isClassic ? DS.Colors.accent : skin.accentColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let calName = event.calendarName {
                    Text(calName)
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
            }
        }
    }

    // MARK: - Hover Actions

    private var hoverActions: some View {
        HStack(spacing: DS.Spacing.xs) {
            if let meetingURL = event.meetingLink {
                Button {
                    Haptics.tap()
                    NSWorkspace.shared.open(meetingURL)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: DS.Size.iconMedium, weight: .medium))
                        .foregroundStyle(DS.Colors.accent)
                }
                .buttonStyle(.borderless)
                .help("Join \(event.meetingServiceName ?? "meeting")")
                .accessibilityLabel("Join \(event.meetingServiceName ?? "meeting")")
            }

            if event.isUpcoming {
                Menu {
                    reminderMenuItems
                } label: {
                    Image(systemName: "bell.badge")
                        .font(.system(size: DS.Size.iconMedium, weight: .medium))
                        .foregroundStyle(skin.resolvedTextSecondary)
                }
                .buttonStyle(.borderless)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Set reminder")
                .accessibilityLabel("Set reminder")
            }

            if isLocal {
                if event.isRecurring {
                    Menu {
                        Button("Delete This Event Only", role: .destructive) {
                            Haptics.impact()
                            triggerDeleteWithDisintegration { onDeleteOccurrence?(event) }
                        }
                        Button("Delete All Events", role: .destructive) {
                            Haptics.impact()
                            triggerDeleteWithDisintegration { onDeleteSeries?(event) }
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: DS.Size.iconLarge, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(skin.resolvedDestructiveColor)
                    }
                    .buttonStyle(.borderless)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Delete recurring event")
                } else {
                    Button {
                        Haptics.impact()
                        triggerDeleteWithDisintegration { onDelete?(event) }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: DS.Size.iconLarge, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(skin.resolvedDestructiveColor)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete event")
                    .accessibilityLabel("Delete event")
                }
            }
        }
        .transition(
            .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            )
        )
    }

    private func timeUntilText(_ now: Date) -> String {
        let secondsUntilStart = Int(event.startDate.timeIntervalSince(now))
        if secondsUntilStart > 0 {
            // Event hasn't started yet
            if secondsUntilStart < 60 { return "in \(secondsUntilStart)s" }
            let minutes = secondsUntilStart / 60
            if minutes < 60 { return "in \(minutes)m" }
            let hours = minutes / 60
            if hours >= 24 {
                let days = hours / 24
                let remainingHours = hours % 24
                if remainingHours == 0 { return "in \(days)d" }
                return "in \(days)d \(remainingHours)h"
            }
            let mins = minutes % 60
            if mins == 0 { return "in \(hours)h" }
            return "in \(hours)h \(mins)m"
        }
        // Event has started or starting now
        let secondsUntilEnd = Int(event.endDate.timeIntervalSince(now))
        if secondsUntilEnd > 0 {
            if secondsUntilEnd < 60 {
                return "\(secondsUntilEnd)s left"
            }
            let minutesEnd = secondsUntilEnd / 60
            let hours = minutesEnd / 60
            let mins = minutesEnd % 60
            if hours == 0 { return "\(mins)m left" }
            if mins == 0 { return "\(hours)h left" }
            return "\(hours)h \(mins)m left"
        }
        return "now"
    }

    private func pomodoroSegmentColor(_ segment: CalendarEvent.PomodoroSegment) -> Color {
        switch segment {
        case .work: skin.accentColor
        case .shortBreak: skin.resolvedSuccessColor
        case .longBreak: DS.Colors.info
        }
    }

    private func triggerDeleteWithDisintegration(action: @escaping () -> Void) {
        guard !isDisintegrating else { return }
        pendingDeleteAction = action
        reminderService.beginDisintegration(for: event.id)
        isDisintegrating = true
    }

    private func eventProgress(_ now: Date) -> Double {
        guard event.startDate <= now && event.endDate > now else { return 0 }
        let total = event.endDate.timeIntervalSince(event.startDate)
        guard total > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(event.startDate)
        return min(max(elapsed / total, 0), 1)
    }

    @ViewBuilder
    private var reminderMenuItems: some View {
        let activeReminders = reminderService.activeReminderMinutes(for: event)
        let customReminders = activeReminders.filter { active in 
            !DS.snoozeOptions.contains { $0.minutes == active }
        }
        let allOptions = (DS.snoozeOptions.map { $0.minutes } + customReminders).sorted()

        ForEach(allOptions, id: \.self) { minutes in
            Toggle(isOn: Binding(
                get: { activeReminders.contains(minutes) },
                set: { isSet in
                    var current = Set(activeReminders)
                    if isSet {
                        current.insert(minutes)
                    } else {
                        current.remove(minutes)
                    }
                    reminderService.updateLocalReminder(for: event.id, minutes: Array(current).sorted())
                }
            )) {
                if let option = DS.snoozeOptions.first(where: { $0.minutes == minutes }) {
                    Text(option.label)
                } else {
                    Text(DS.formatMinutes(minutes))
                }
            }
        }
        Divider()
        Button("Clear All") {
            reminderService.updateLocalReminder(for: event.id, minutes: [])
        }
        .disabled(activeReminders.isEmpty)
    }
}
