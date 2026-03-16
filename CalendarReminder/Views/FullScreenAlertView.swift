import SwiftUI

struct FullScreenAlertView: View {
    let event: CalendarEvent
    let minutesBefore: Int
    let onDismiss: () -> Void
    let onSnooze: (Int) -> Void

    @State private var secondsRemaining: Int = 0
    @State private var countdownTimer: Timer?
    @State private var pulseScale: CGFloat = 1.0
    @State private var appeared = false

    var body: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [
                    Color.black,
                    gradientAccent.opacity(0.3),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Subtle radial glow behind the timer
            RadialGradient(
                colors: [countdownColor.opacity(0.15), .clear],
                center: .center,
                startRadius: 50,
                endRadius: 300
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Bell icon with pulse
                ZStack {
                    Circle()
                        .fill(countdownColor.opacity(0.08))
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulseScale)

                    Circle()
                        .fill(countdownColor.opacity(0.04))
                        .frame(width: 160, height: 160)
                        .scaleEffect(pulseScale * 0.95)

                    Image(systemName: secondsRemaining <= 0 ? "bell.slash.fill" : "bell.badge.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(countdownColor.gradient)
                        .symbolRenderingMode(.hierarchical)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                        pulseScale = 1.12
                    }
                }

                Spacer().frame(height: 32)

                // Header
                Text(headerText)
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))

                Spacer().frame(height: 12)

                // Countdown
                Text(countdownText)
                    .font(.system(size: 80, weight: .heavy, design: .monospaced))
                    .foregroundStyle(countdownColor.gradient)
                    .shadow(color: countdownColor.opacity(0.4), radius: 20)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: secondsRemaining)

                Spacer().frame(height: 24)

                // Event title
                Text(event.title)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)

                Spacer().frame(height: 16)

                // Event details
                HStack(spacing: 16) {
                    DetailPill(icon: "clock.fill", text: event.formattedTimeRange)

                    if let location = event.location, !location.isEmpty {
                        DetailPill(icon: "location.fill", text: location)
                    }
                }

                Spacer()

                // Action buttons
                HStack(spacing: 16) {
                    Menu {
                        Button { cleanup(); onSnooze(5) } label: {
                            Label("5 minutes", systemImage: "5.circle")
                        }
                        Button { cleanup(); onSnooze(10) } label: {
                            Label("10 minutes", systemImage: "10.circle")
                        }
                        Button { cleanup(); onSnooze(15) } label: {
                            Label("15 minutes", systemImage: "15.circle")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("Snooze")
                        }
                        .font(.system(.title3, design: .rounded).weight(.medium))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)
                        )
                        .overlay(
                            Capsule()
                                .stroke(.white.opacity(0.15), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)

                    Button(action: { cleanup(); onDismiss() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                            Text("Dismiss")
                        }
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(.white))
                        .shadow(color: .white.opacity(0.2), radius: 20)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }

                Spacer().frame(height: 16)

                Text("Press Enter to dismiss")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundColor(.white.opacity(0.25))

                Spacer().frame(height: 40)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startCountdown()
            withAnimation(.easeOut(duration: 0.5)) {
                appeared = true
            }
        }
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
        return .cyan
    }

    private var gradientAccent: Color {
        if secondsRemaining <= 120 { return .red }
        if secondsRemaining <= 300 { return .orange }
        return .indigo
    }

    private var headerText: String {
        if secondsRemaining <= 0 {
            return "Meeting started!"
        }
        return "Meeting in"
    }
}

// MARK: - Detail Pill

private struct DetailPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.system(.subheadline, design: .rounded))
        }
        .foregroundColor(.white.opacity(0.8))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
    }
}
