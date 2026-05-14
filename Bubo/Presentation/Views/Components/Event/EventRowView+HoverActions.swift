import SwiftUI
import BuboDomain

// MARK: - EventRowView: Hover Actions
//
// Trailing hover-action cluster (snooze, complete, delete with
// disintegration, reminder menu).
// Extracted from EventRowView.swift.

extension EventRowView {

    // MARK: - Hover Actions

    var hoverActions: some View {
        HStack(spacing: DS.Spacing.xs) {
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
                if let findBetterTime = onFindBetterTime {
                    Button {
                        Haptics.impact()
                        findBetterTime(event)
                    } label: {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: DS.Size.iconMedium, weight: .medium))
                            .foregroundStyle(skin.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help("Find a better time")
                    .accessibilityLabel("Find a better time for this event")
                }
                // Match BacklogTaskRow's xmark hover-affordance for a single
                // delete language across the app — the prior filled-minus
                // glyph also outweighed its peer icons (bell, chevron) and
                // read as the row's primary action.
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
                        Image(systemName: "xmark")
                            .font(.system(size: DS.Size.iconMedium, weight: .medium))
                            .foregroundStyle(skin.resolvedDestructiveColor)
                    }
                    .buttonStyle(.borderless)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Delete recurring event")
                    .accessibilityLabel("Delete recurring event")
                } else {
                    Button {
                        Haptics.impact()
                        triggerDeleteWithDisintegration { onDelete?(event) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: DS.Size.iconMedium, weight: .medium))
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

    func timeUntilText(_ now: Date) -> String {
        let secondsUntilStart = Int(event.startDate.timeIntervalSince(now))
        if secondsUntilStart > 0 {
            // Event hasn't started yet
            if secondsUntilStart < 60 { return "in\u{00A0}\(secondsUntilStart)\u{00A0}s" }
            let minutes = secondsUntilStart / 60
            if minutes < 60 { return "in\u{00A0}\(minutes)\u{00A0}min" }
            let hours = minutes / 60
            if hours >= 24 {
                let days = hours / 24
                let remainingHours = hours % 24
                if remainingHours == 0 { return "in\u{00A0}\(days)\u{00A0}d" }
                return "in\u{00A0}\(days)\u{00A0}d\u{00A0}\(remainingHours)\u{00A0}h"
            }
            let mins = minutes % 60
            if mins == 0 { return "in\u{00A0}\(hours)\u{00A0}h" }
            return "in\u{00A0}\(hours)\u{00A0}h\u{00A0}\(mins)\u{00A0}min"
        }
        // Event has started or starting now
        let secondsUntilEnd = Int(event.endDate.timeIntervalSince(now))
        if secondsUntilEnd > 0 {
            if secondsUntilEnd < 60 {
                return "\(secondsUntilEnd)\u{00A0}s left"
            }
            let minutesEnd = secondsUntilEnd / 60
            let hours = minutesEnd / 60
            let mins = minutesEnd % 60
            if hours == 0 { return "\(mins)\u{00A0}min left" }
            if mins == 0 { return "\(hours)\u{00A0}h left" }
            return "\(hours)\u{00A0}h\u{00A0}\(mins)\u{00A0}min left"
        }
        return "now"
    }

    func pomodoroSegmentColor(_ segment: CalendarEvent.PomodoroSegment) -> Color {
        switch segment {
        case .work: skin.accentColor
        case .shortBreak: skin.resolvedSuccessColor
        case .longBreak: DS.Colors.info
        }
    }

    func triggerDeleteWithDisintegration(action: @escaping () -> Void) {
        guard !isDisintegrating else { return }
        pendingDeleteAction = action
        reminderService.beginDisintegration(for: event.id)
        isDisintegrating = true
    }

    func eventProgress(_ now: Date) -> Double {
        guard event.startDate <= now && event.endDate > now else { return 0 }
        let total = event.endDate.timeIntervalSince(event.startDate)
        guard total > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(event.startDate)
        return min(max(elapsed / total, 0), 1)
    }

    @ViewBuilder
    var reminderMenuItems: some View {
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
