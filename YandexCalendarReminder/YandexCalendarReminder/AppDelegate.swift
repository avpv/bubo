import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var alertWindow: NSWindow?
    private var alertObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        alertObserver = NotificationCenter.default.addObserver(
            forName: .showFullScreenAlert,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?["event"] as? CalendarEvent,
                  let minutes = notification.userInfo?["minutesBefore"] as? Int else { return }
            self?.showAlert(event: event, minutesBefore: minutes)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = alertObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func dismissAlert() {
        alertWindow?.close()
        alertWindow = nil
    }

    private func showAlert(event: CalendarEvent, minutesBefore: Int) {
        alertWindow?.close()

        guard let screen = NSScreen.main else { return }

        let alertView = FullScreenAlertContentView(
            event: event,
            minutesBefore: minutesBefore,
            onDismiss: { [weak self] in
                self?.dismissAlert()
            },
            onSnooze: { [weak self] minutes in
                self?.dismissAlert()
                // Post snooze notification
                NotificationCenter.default.post(
                    name: .snoozeReminder,
                    object: nil,
                    userInfo: ["event": event, "minutes": minutes]
                )
            }
        )

        let hostingView = NSHostingView(rootView: alertView)

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)

        NSApplication.shared.activate(ignoringOtherApps: true)
        alertWindow = window

        // Auto-dismiss after 60 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.dismissAlert()
        }

        NSSound.beep()
    }
}

extension Notification.Name {
    static let snoozeReminder = Notification.Name("snoozeReminder")
}

// MARK: - Full Screen Alert View

struct FullScreenAlertContentView: View {
    let event: CalendarEvent
    let minutesBefore: Int
    let onDismiss: () -> Void
    let onSnooze: (Int) -> Void

    @State private var secondsRemaining: Int = 0
    @State private var countdownTimer: Timer?

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer()

                Image(systemName: "bell.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.yellow)
                    .shadow(color: .yellow.opacity(0.5), radius: 20)

                Text(headerText)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.white)

                // Live countdown timer
                Text(countdownText)
                    .font(.system(size: 72, weight: .heavy, design: .monospaced))
                    .foregroundColor(countdownColor)
                    .shadow(color: countdownColor.opacity(0.5), radius: 10)

                Text(event.title)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                HStack(spacing: 20) {
                    Label(event.formattedTimeRange, systemImage: "clock.fill")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.9))

                    if let location = event.location, !location.isEmpty {
                        Label(location, systemImage: "location.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.9))
                    }
                }

                Spacer()

                // Action buttons
                HStack(spacing: 20) {
                    Menu {
                        Button("Через 5 минут") { cleanup(); onSnooze(5) }
                        Button("Через 10 минут") { cleanup(); onSnooze(10) }
                        Button("Через 15 минут") { cleanup(); onSnooze(15) }
                    } label: {
                        Text("Отложить")
                            .font(.title3)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 14)
                            .background(
                                Capsule()
                                    .stroke(.white.opacity(0.5), lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: { cleanup(); onDismiss() }) {
                        Text("Понятно")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.black)
                            .padding(.horizontal, 60)
                            .padding(.vertical, 16)
                            .background(Capsule().fill(.white))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }

                Text("Нажмите Enter или кнопку для закрытия")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.4))

                Spacer().frame(height: 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startCountdown() }
        .onDisappear { cleanup() }
    }

    // MARK: - Countdown

    private func startCountdown() {
        updateSecondsRemaining()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            updateSecondsRemaining()
        }
    }

    private func updateSecondsRemaining() {
        let remaining = Int(event.startDate.timeIntervalSinceNow)
        secondsRemaining = max(remaining, 0)
    }

    private func cleanup() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private var countdownText: String {
        if secondsRemaining <= 0 {
            return "00:00"
        }
        let minutes = secondsRemaining / 60
        let seconds = secondsRemaining % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return String(format: "%d:%02d:%02d", hours, mins, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var countdownColor: Color {
        if secondsRemaining <= 0 { return .red }
        if secondsRemaining <= 120 { return .red }
        if secondsRemaining <= 300 { return .orange }
        return .white
    }

    private var headerText: String {
        if secondsRemaining <= 0 {
            return "Встреча началась!"
        }
        return "Встреча через"
    }
}
