import SwiftUI

struct MenuBarView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var reminderService: ReminderService
    @ObservedObject var networkMonitor: NetworkMonitor

    @State private var showingAddEvent = false
    @State private var editingEvent: CalendarEvent? = nil
    @State private var showingDetail = false
    @State private var detailEvent: CalendarEvent? = nil
    @State private var hasStartedSync = false

    var body: some View {
        Group {
            if showingAddEvent {
                AddEventView(
                    reminderService: reminderService,
                    isPresented: $showingAddEvent,
                    editingEvent: editingEvent
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if showingDetail, let event = detailEvent {
                EventDetailView(
                    event: event,
                    isPresented: $showingDetail,
                    onEdit: { event in
                        showingDetail = false
                        editingEvent = event
                        showingAddEvent = true
                    },
                    onDelete: { event in
                        reminderService.removeLocalEvent(id: event.id)
                        showingDetail = false
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                mainContent
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingAddEvent)
        .animation(.easeInOut(duration: 0.2), value: showingDetail)
        .onAppear {
            guard !hasStartedSync else { return }
            hasStartedSync = true
            reminderService.setNetworkMonitor(networkMonitor)
            reminderService.updateSettings(settings)
            reminderService.startSync()
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                OwlIcon(size: 18)
                Text("Reminder")
                    .font(.headline)
                Spacer()

                HStack(spacing: 6) {
                    if !networkMonitor.isConnected {
                        Image(systemName: "wifi.slash")
                            .foregroundColor(.red)
                            .font(.system(size: 12))
                            .help("No internet connection")
                            .accessibilityLabel("No internet connection")
                    }

                    if settings.isDoNotDisturbActive {
                        Image(systemName: "moon.fill")
                            .foregroundColor(.indigo)
                            .font(.system(size: 12))
                            .help("Do Not Disturb")
                            .accessibilityLabel("Do Not Disturb is active")
                    }

                    if reminderService.isSyncing {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 14, height: 14)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Status messages
            if !networkMonitor.isConnected {
                StatusBanner(
                    icon: "wifi.slash",
                    text: "No connection. Showing cached data",
                    color: .orange
                )
            } else if reminderService.isUsingCache {
                StatusBanner(
                    icon: "arrow.triangle.2.circlepath",
                    text: "Showing cached data",
                    color: .yellow
                )
            }

            if let error = reminderService.syncError, networkMonitor.isConnected {
                StatusBanner(icon: "exclamationmark.triangle.fill", text: error, color: .orange)
            }

            // Events
            if reminderService.eventsByDay.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                    Text("No upcoming meetings")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Text("Your schedule is clear")
                        .font(.caption)
                        .foregroundColor(.tertiary)
                    Button {
                        editingEvent = nil
                        showingAddEvent = true
                    } label: {
                        Label("Add Event", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                List {
                    ForEach(reminderService.eventsByDay, id: \.date) { dayGroup in
                        Section {
                            ForEach(dayGroup.events) { event in
                                EventRowView(
                                    event: event,
                                    reminderService: reminderService,
                                    onEdit: { event in
                                        editingEvent = event
                                        showingAddEvent = true
                                    },
                                    onDelete: { event in
                                        reminderService.removeLocalEvent(id: event.id)
                                    },
                                    onTap: { event in
                                        detailEvent = event
                                        showingDetail = true
                                    }
                                )
                            }
                        } header: {
                            DaySectionHeader(date: dayGroup.date, count: dayGroup.events.count)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: 360)
            }

            Divider()

            // Actions
            if let lastSync = reminderService.lastSyncDate {
                Text(lastSync, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
                    .padding(.bottom, -4)
            }

            HStack(spacing: 6) {
                Button(action: {
                    editingEvent = nil
                    showingAddEvent = true
                }) {
                    Label("Add", systemImage: "plus")
                }
                .help("Add a new event (⌘N)")
                .keyboardShortcut("n", modifiers: .command)

                Button(action: { reminderService.syncNow() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!networkMonitor.isConnected)
                .help("Sync calendars now (⌘R)")
                .keyboardShortcut("r", modifiers: .command)

                Spacer()

                Button(action: {
                    if let window = NSApp.keyWindow {
                        window.close()
                    }
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                        if #available(macOS 14.0, *) {
                            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        } else {
                            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                        }
                    }
                }) {
                    Label("Settings", systemImage: "gear")
                }
                .help("Open settings")

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Label("Quit", systemImage: "power")
                }
                .help("Quit Reminder (⌘Q)")
                .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .frame(width: 340)
    }
}
