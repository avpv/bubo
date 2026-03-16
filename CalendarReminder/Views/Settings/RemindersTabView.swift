import SwiftUI

struct RemindersTabView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Reminder Intervals
                SettingsCard(icon: "bell.badge", title: "Reminder Intervals", description: "When to notify you before events") {
                    VStack(spacing: 6) {
                        ForEach($settings.intervals) { $interval in
                            HStack(spacing: 10) {
                                Toggle(isOn: $interval.isEnabled) {
                                    HStack(spacing: 6) {
                                        Image(systemName: interval.isEnabled ? "bell.fill" : "bell.slash")
                                            .font(.caption)
                                            .foregroundColor(interval.isEnabled ? .accentColor : .secondary)
                                            .frame(width: 16)
                                        Text("\(interval.displayText) before")
                                            .font(.system(.subheadline, design: .rounded))
                                    }
                                }
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .onChange(of: interval.isEnabled) { _ in save() }

                                Button {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        settings.intervals.removeAll { $0.id == interval.id }
                                        save()
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.03))
                            )
                        }

                        HStack(spacing: 8) {
                            Stepper(
                                "\(viewModel.newIntervalMinutes) min",
                                value: $viewModel.newIntervalMinutes,
                                in: 1...120
                            )
                            .font(.system(.subheadline, design: .rounded))

                            Button {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    settings.intervals.append(ReminderInterval(minutes: viewModel.newIntervalMinutes))
                                    save()
                                }
                            } label: {
                                Label("Add", systemImage: "plus.circle.fill")
                                    .font(.system(.caption, design: .rounded).weight(.medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.top, 4)
                    }
                }

                // Notification Types
                SettingsCard(icon: "app.badge", title: "Notification Style", description: "Choose how you want to be notified") {
                    VStack(spacing: 8) {
                        Toggle(isOn: $settings.showFullScreenAlert) {
                            HStack(spacing: 8) {
                                Image(systemName: "rectangle.inset.filled")
                                    .font(.subheadline)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Full-screen alert")
                                        .font(.system(.subheadline, design: .rounded))
                                    Text("Covers the screen with countdown timer")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: settings.showFullScreenAlert) { _ in save() }

                        Divider()

                        Toggle(isOn: $settings.showSystemNotification) {
                            HStack(spacing: 8) {
                                Image(systemName: "bell.badge.fill")
                                    .font(.subheadline)
                                    .foregroundColor(.orange)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("System notification")
                                        .font(.system(.subheadline, design: .rounded))
                                    Text("Standard macOS notification banner")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: settings.showSystemNotification) { _ in save() }
                    }
                }

                // Do Not Disturb
                SettingsCard(icon: "moon.fill", title: "Do Not Disturb", description: "Silence reminders during specific hours") {
                    VStack(spacing: 8) {
                        Toggle(isOn: $settings.doNotDisturbEnabled) {
                            Text("Enable Do Not Disturb")
                                .font(.system(.subheadline, design: .rounded))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: settings.doNotDisturbEnabled) { _ in save() }

                        if settings.doNotDisturbEnabled {
                            HStack(spacing: 12) {
                                DatePicker("From", selection: $settings.doNotDisturbFrom, displayedComponents: .hourAndMinute)
                                    .font(.system(.subheadline, design: .rounded))
                                    .onChange(of: settings.doNotDisturbFrom) { _ in save() }

                                DatePicker("To", selection: $settings.doNotDisturbTo, displayedComponents: .hourAndMinute)
                                    .font(.system(.subheadline, design: .rounded))
                                    .onChange(of: settings.doNotDisturbTo) { _ in save() }
                            }

                            if settings.isDoNotDisturbActive {
                                HStack(spacing: 4) {
                                    Image(systemName: "moon.fill")
                                        .font(.caption2)
                                    Text("Currently active")
                                        .font(.system(.caption, design: .rounded).weight(.medium))
                                }
                                .foregroundColor(.indigo)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color.indigo.opacity(0.1))
                                )
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func save() {
        viewModel.saveSettings(settings, reminderService)
    }
}
