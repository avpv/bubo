import SwiftUI

struct FullScreenAlertView: View {
    let event: CalendarEvent
    let minutesBefore: Int
    let onDismiss: () -> Void
    let onSnooze: (Int) -> Void

    @State private var secondsRemaining: Int = 0
    @State private var countdownTimer: Timer?
    @State private var isVisible = false
    @State private var snoozeHovered = false
    @State private var joinHovered = false
    @State private var dismissHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.activeSkin) private var skin

    private var skinAccent: Color {
        skin.isClassic ? Color.accentColor : skin.accentColor
    }

    private var skinSecondary: Color {
        skin.isClassic ? Color.accentColor.opacity(0.85) : skin.resolvedSecondaryAccent
    }

    var body: some View {
        ZStack {
            // Background: material + skin-tinted overlay
            Rectangle()
                .fill(DS.Materials.overlay)
                .ignoresSafeArea()

            Color.black.opacity(contrast == .increased ? 0.8 : 0.6)
                .ignoresSafeArea()

            // Ambient skin glow behind content
            if !skin.isClassic {
                RadialGradient(
                    colors: [skinAccent.opacity(0.15), skinSecondary.opacity(0.05), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 600
                )
                .ignoresSafeArea()
            }

            VStack(spacing: DS.Spacing.xxxl) {
                Spacer()

                bellIcon

                Text(headerText)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                // Live countdown timer
                Text(countdownText)
                    .font(.system(size: 72, weight: .heavy, design: .monospaced))
                    .foregroundStyle(countdownDisplayColor)
                    .shadow(color: countdownDisplayColor.opacity(0.5), radius: 12)
                    .contentTransition(.numericText())
                    .motionAwareAnimation(.linear(duration: 0.3), value: secondsRemaining, reduceMotion: reduceMotion)

                Text(event.title)
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                HStack(spacing: 20) {
                    Label(event.formattedTimeRange, systemImage: "clock.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.9))

                    if let location = event.location, !location.isEmpty {
                        Label(location, systemImage: "location.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }

                Spacer()

                // Action buttons
                HStack(spacing: 20) {
                    // Snooze button — outlined, skin-tinted
                    Menu {
                        ForEach(DS.snoozeOptions) { option in
                            Button("In \(option.label)") {
                                Haptics.tap()
                                cleanup()
                                onSnooze(option.minutes)
                            }
                        }
                    } label: {
                        Text("Snooze")
                            .font(.system(.title3, design: .rounded, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 14)
                            .background(
                                Capsule()
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        Capsule()
                                            .fill(skinAccent.opacity(snoozeHovered ? 0.2 : 0.0))
                                    )
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [skinAccent.opacity(0.6), skinSecondary.opacity(0.3)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1.5
                                    )
                            )
                            .shadow(color: skinAccent.opacity(snoozeHovered ? 0.3 : 0.0), radius: 12, y: 4)
                            .scaleEffect(snoozeHovered ? 1.03 : 1.0)
                            .animation(skin.resolvedMicroAnimation, value: snoozeHovered)
                    }
                    .buttonStyle(.plain)
                    .onHover { snoozeHovered = $0 }

                    // Join meeting button — skin gradient fill
                    if let meetingURL = event.meetingLink, let serviceName = event.meetingServiceName {
                        Button {
                            Haptics.impact()
                            NSWorkspace.shared.open(meetingURL)
                            cleanup()
                            onDismiss()
                        } label: {
                            Label("Join \(serviceName)", systemImage: "video.fill")
                                .font(.system(.title2, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 40)
                                .padding(.vertical, 16)
                                .background(
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [skinAccent, skinSecondary],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                                )
                                .shadow(color: skinAccent.opacity(0.5), radius: joinHovered ? 16 : 10, y: joinHovered ? 6 : 4)
                                .scaleEffect(joinHovered ? 1.04 : 1.0)
                                .animation(skin.resolvedMicroAnimation, value: joinHovered)
                        }
                        .buttonStyle(.plain)
                        .onHover { joinHovered = $0 }
                        .keyboardShortcut(.return, modifiers: [])
                        .accessibilityLabel("Join \(serviceName)")
                    }

                    // Dismiss button — white pill with skin accent on hover
                    Button(action: {
                        Haptics.impact()
                        cleanup()
                        onDismiss()
                    }) {
                        Text("Dismiss")
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .foregroundStyle(dismissHovered ? skinAccent : .black)
                            .padding(.horizontal, 60)
                            .padding(.vertical, 16)
                            .background(
                                Capsule()
                                    .fill(.white)
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(skinAccent.opacity(dismissHovered ? 0.5 : 0.0), lineWidth: 1.5)
                            )
                            .shadow(color: .white.opacity(dismissHovered ? 0.3 : 0.15), radius: dismissHovered ? 14 : 8, y: dismissHovered ? 5 : 3)
                            .scaleEffect(dismissHovered ? 1.03 : 1.0)
                            .animation(skin.resolvedMicroAnimation, value: dismissHovered)
                    }
                    .buttonStyle(.plain)
                    .onHover { dismissHovered = $0 }
                    .keyboardShortcut(event.meetingLink != nil ? .escape : .return, modifiers: [])
                    .accessibilityLabel("Dismiss alert")
                    .accessibilityHint("Press Enter or click to dismiss")
                }

                Text("Press Enter or Esc to dismiss")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .accessibilityHidden(true)

                Spacer().frame(height: 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // HIG: Handle Escape key without hidden zero-size button hack
        .onKeyPress(.escape) {
            cleanup()
            onDismiss()
            return .handled
        }
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : (reduceMotion ? 1 : 0.92))
        .onAppear {
            Haptics.impact()
            startCountdown()
            if reduceMotion {
                isVisible = true
            } else {
                withAnimation(DS.Animation.smoothSpring) {
                    isVisible = true
                }
            }
        }
        .onDisappear { cleanup() }
    }

    /// Countdown color: uses skin accent when plenty of time remains,
    /// falls back to urgency colors (warning/error) when imminent.
    private var countdownDisplayColor: Color {
        if secondsRemaining <= 120 { return DS.Colors.error }
        if secondsRemaining <= 300 { return DS.Colors.warning }
        return skinAccent
    }

    // MARK: - Bell Icon

    private var bellIcon: some View {
        Image(systemName: "bell.fill")
            .font(.system(size: 60))
            .foregroundStyle(
                LinearGradient(
                    colors: [skinAccent, skinSecondary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .shadow(color: skinAccent.opacity(0.5), radius: 20)
            .symbolEffect(
                .bounce,
                options: reduceMotion ? .default : .repeating.speed(0.4),
                value: isVisible
            )
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

    private var headerText: String {
        if secondsRemaining <= 0 {
            return "Meeting started!"
        }
        return "Meeting in"
    }
}
