import SwiftUI

struct FullScreenAlertView: View {
    let event: CalendarEvent
    let minutesBefore: Int
    let onDismiss: () -> Void
    let onSnooze: (Int) -> Void

    @State private var secondsRemaining: Int = 0
    @State private var countdownTimer: Timer?
    @State private var isVisible = false

    var body: some View {
        ZStack {
            // Native material background
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer()

                bellIcon

                Text(headerText)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.white)

                // Live countdown timer
                Text(countdownText)
                    .font(.system(size: 72, weight: .heavy, design: .monospaced))
                    .foregroundColor(countdownColor)
                    .shadow(color: countdownColor.opacity(0.5), radius: 10)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.3), value: secondsRemaining)

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
                        Button("In 5 minutes") { cleanup(); onSnooze(5) }
                        Button("In 10 minutes") { cleanup(); onSnooze(10) }
                        Button("In 15 minutes") { cleanup(); onSnooze(15) }
                    } label: {
                        Text("Snooze")
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
                        Text("Dismiss")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.black)
                            .padding(.horizontal, 60)
                            .padding(.vertical, 16)
                            .background(Capsule().fill(.white))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                    .accessibilityLabel("Dismiss alert")
                    .accessibilityHint("Press Enter or click to dismiss")
                }

                Text("Press Enter or click a button to dismiss")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.4))
                    .accessibilityHidden(true)

                Spacer().frame(height: 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.95)
        .onAppear {
            startCountdown()
            withAnimation(.easeOut(duration: 0.3)) {
                isVisible = true
            }
        }
        .onDisappear { cleanup() }
    }

    @ViewBuilder
    private var bellIcon: some View {
        let base = Image(systemName: "bell.fill")
            .font(.system(size: 60))
            .foregroundColor(.yellow)
            .shadow(color: .yellow.opacity(0.5), radius: 20)
        if #available(macOS 14.0, *) {
            base.symbolEffect(.pulse, options: .repeating)
        } else {
            base
        }
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
        if secondsRemaining <= 120 { return .red }
        if secondsRemaining <= 300 { return .orange }
        return .white
    }

    private var headerText: String {
        if secondsRemaining <= 0 {
            return "Meeting started!"
        }
        return "Meeting in"
    }
}
