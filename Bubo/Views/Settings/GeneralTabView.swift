import ServiceManagement
import SwiftUI

struct ThemeColorPreview: View {
    let colors: [Color]
    var size: CGFloat = 12

    var body: some View {
        if colors.count == 1 {
            Circle()
                .fill(colors[0])
                .frame(width: size, height: size)
        } else {
            Circle()
                .fill(
                    LinearGradient(
                        colors: colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
        }
    }
}

struct GeneralTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(ReminderService.self) var reminderService
    @State private var loginItemError: String?

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    settings.launchAtLogin = newValue
                } catch {
                    loginItemError = error.localizedDescription
                }
            }
        )
    }

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
            SettingsPlatter("Refresh") {
                Picker("Refresh interval", selection: $settings.syncIntervalMinutes) {
                    Text("1 minute").tag(1)
                    Text("3 minutes").tag(3)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
            }

            SettingsPlatter("Startup") {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
            }

            SettingsPlatter("Event Counter Badge") {
                Toggle("Show event count in menu bar", isOn: $settings.showBadgeCount)

                if settings.showBadgeCount {
                    Picker("Count mode", selection: $settings.badgeCountMode) {
                        ForEach(BadgeCountMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    if settings.badgeCountMode == .timeWindow {
                        Stepper(
                            "Time window: \(settings.badgeTimeWindowHours) h",
                            value: $settings.badgeTimeWindowHours,
                            in: 1...ReminderService.fetchWindowDays * 24
                        )
                    }
                }
            }

            SettingsPlatter("Appearance") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Background")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                        ForEach(AppBackgroundStyle.allCases) { style in
                            let isSelected = settings.backgroundStyle == style
                            Button {
                                settings.backgroundStyle = style
                            } label: {
                                VStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(style.previewGradient)
                                        .frame(height: 28)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(
                                                    isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                                                    lineWidth: isSelected ? 2 : 0.5
                                                )
                                        )
                                    Text(style.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(isSelected ? .primary : .secondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            SettingsPlatter("Status") {
                if let lastSync = reminderService.lastSyncDate {
                    LabeledContent("Last refresh") {
                        Text(lastSync.formatted())
                    }
                }

                LabeledContent("Calendar events") {
                    Text("\(reminderService.upcomingEvents.count)")
                }

                LabeledContent("Local events") {
                    Text("\(reminderService.localEvents.count)")
                }

                if reminderService.isUsingCache {
                    Label("Using cached data", systemImage: "internaldrive")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
            }

            SettingsPlatter {
                VStack(spacing: DS.Spacing.xs) {
                    HStack {
                        Spacer()
                        Text("Bubo \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        Link("GitHub Project", destination: URL(string: "https://github.com/avpv/bubo")!)
                            .font(.caption2)
                        Spacer()
                    }
                }
            }
            }
            .padding(20)
        }
        .onAppear {
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .alert("Cannot change login item", isPresented: .init(
            get: { loginItemError != nil },
            set: { if !$0 { loginItemError = nil } }
        )) {
            Button("OK") { loginItemError = nil }
        } message: {
            Text(loginItemError ?? "")
        }
    }
}
