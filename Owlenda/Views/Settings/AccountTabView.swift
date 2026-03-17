import EventKit
import SwiftUI

struct AccountTabView: View {
    @EnvironmentObject var settings: ReminderSettings
    @EnvironmentObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Calendar Access") {
                if viewModel.appleCalendarAccessGranted {
                    HStack {
                        Label("Access granted", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Spacer()
                        Text("\(viewModel.availableAppleCalendars.count) calendars")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                } else {
                    let status = AppleCalendarService.authorizationStatus
                    if status == .denied || status == .restricted {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Label("Calendar access denied", systemImage: "xmark.circle.fill")
                                .foregroundColor(.red)
                            Text("Grant access in System Settings → Privacy & Security → Calendars")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                            }
                            .controlSize(.small)
                        }
                    } else {
                        Button {
                            viewModel.requestAppleCalendarAccess()
                        } label: {
                            Label("Grant Calendar Access", systemImage: "calendar")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Text("Owlenda reads events from all accounts configured in the Calendar app — iCloud, Google, Exchange, CalDAV, and others.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if viewModel.appleCalendarAccessGranted {
                Section("Accounts") {
                    if viewModel.appleCalendarsByAccount.isEmpty {
                        Text("No accounts found")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.appleCalendarsByAccount, id: \.account) { group in
                            HStack {
                                Label(group.account, systemImage: accountIcon(for: group.account))
                                Spacer()
                                Text("\(group.calendars.count) calendars")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    }

                    Text("Manage accounts in System Settings → Internet Accounts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if viewModel.appleCalendarAccessGranted && viewModel.availableAppleCalendars.isEmpty {
                viewModel.loadAppleCalendars()
            }
        }
    }

    private func accountIcon(for accountName: String) -> String {
        let name = accountName.lowercased()
        if name.contains("icloud") { return "icloud" }
        if name.contains("google") || name.contains("gmail") { return "envelope" }
        if name.contains("exchange") || name.contains("outlook") || name.contains("microsoft") { return "building.2" }
        if name.contains("yahoo") { return "envelope" }
        return "calendar"
    }
}
