import SwiftUI

struct FullScreenAlertView: View {
    let event: CalendarEvent
    let minutesBefore: Int
    let onDismiss: () -> Void
    let onSnooze: (Int) -> Void

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
        // HIG: Use TimelineView for time-based UI updates instead of Timer.publish
        TimelineView(.periodic(from: .now, by: 1)) { context in
        let secondsRemaining = max(Int(event.startDate.timeIntervalSince(context.date)), 0)
        ZStack {
            // Background: material + skin-tinted overlay
            Rectangle()
                .fill(DS.Materials.overlay)
                .ignoresSafeArea()

            DS.Colors.overlayBackground
                .opacity(contrast == .increased ? DS.Opacity.overlayDark : DS.Opacity.overlayLight)
                .ignoresSafeArea()

            // Ambient skin glow behind content
            if !skin.isClassic {
                RadialGradient(
                    colors: [skinAccent.opacity(DS.Opacity.subtleBorder), skinSecondary.opacity(DS.Opacity.subtleFill), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 600
                )
                .ignoresSafeArea()
            }

            VStack(spacing: DS.Spacing.xxxl) {
                Spacer()

                bellIcon

                // HIG: Use semantic text styles that scale with Dynamic Type
                Text(headerText(secondsRemaining))
                    .font(.system(.largeTitle, design: skin.resolvedFontDesign, weight: skin.resolvedHeadlineFontWeight))
                    .foregroundStyle(DS.Colors.onOverlay)

                // Live countdown timer
                Text(countdownText(secondsRemaining))
                    .font(.system(.largeTitle, design: .monospaced, weight: .heavy))
                    .scaleEffect(1.5)
                    .foregroundStyle(countdownDisplayColor(secondsRemaining))
                    .shadow(color: countdownDisplayColor(secondsRemaining).opacity(0.5), radius: DS.Shadows.buttonRadius)
                    .contentTransition(.numericText())
                    .motionAwareAnimation(.linear(duration: 0.3), value: secondsRemaining, reduceMotion: reduceMotion)

                Text(event.title)
                    .font(.system(.title, design: skin.resolvedFontDesign, weight: skin.resolvedHeadlineFontWeight))
                    .foregroundStyle(DS.Colors.onOverlay)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.xxxl + DS.Spacing.sm)

                HStack(spacing: DS.Spacing.xl) {
                    Label(event.formattedTimeRange, systemImage: "clock.fill")
                        .font(.title2)
                        .foregroundStyle(DS.Colors.onOverlay.opacity(0.9))

                    if let location = event.location, !location.isEmpty {
                        Label(location, systemImage: "location.fill")
                            .font(.title2)
                            .foregroundStyle(DS.Colors.onOverlay.opacity(0.9))
                    }
                }

                Spacer()

                // Action buttons
                HStack(spacing: DS.Spacing.xl) {
                    // Snooze button — outlined, skin-tinted
                    Menu {
                        ForEach(DS.snoozeOptions) { option in
                            Button("In \(option.label)") {
                                Haptics.tap()
                                onSnooze(option.minutes)
                            }
                        }
                    } label: {
                        Text("Snooze")
                            .font(.system(.title3, design: skin.resolvedFontDesign, weight: skin.resolvedFontWeight))
                            .foregroundStyle(DS.Colors.onOverlay)
                            .padding(.horizontal, DS.Spacing.xxxl + DS.Spacing.sm)
                            .padding(.vertical, DS.Spacing.md + DS.Spacing.xxs)
                            .background(
                                Capsule()
                                    .fill(DS.Materials.overlay)
                                    .overlay(
                                        Capsule()
                                            .fill(skinAccent.opacity(snoozeHovered ? skin.hoverFillOpacity * 2.5 : 0))
                                    )
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [skinAccent.opacity(DS.Opacity.overlayLight), skinSecondary.opacity(0.3)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: DS.Border.medium
                                    )
                            )
                            .shadow(color: skinAccent.opacity(snoozeHovered ? skin.hoverShadowOpacity * 1.5 : 0), radius: skin.hoverShadowRadius, y: skin.hoverShadowY)
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
                            onDismiss()
                        } label: {
                            Label("Join \(serviceName)", systemImage: "video.fill")
                                .font(.system(.title2, design: skin.resolvedFontDesign, weight: skin.resolvedHeadlineFontWeight))
                                .foregroundStyle(DS.contrastingForeground(for: skinAccent))
                                .padding(.horizontal, DS.Spacing.xxxl + DS.Spacing.sm)
                                .padding(.vertical, DS.Spacing.lg)
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
                                        .strokeBorder(DS.Colors.onOverlay.opacity(DS.Opacity.glassBorder), lineWidth: DS.Border.thin)
                                )
                                .shadow(color: skinAccent.opacity(0.5), radius: joinHovered ? skin.hoverShadowRadius * 1.3 : skin.hoverShadowRadius * 0.8, y: joinHovered ? skin.hoverShadowY : skin.shadowY)
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
                        onDismiss()
                    }) {
                        Text("Dismiss")
                            .font(.system(.title2, design: skin.resolvedFontDesign, weight: skin.resolvedHeadlineFontWeight))
                            .foregroundStyle(dismissHovered ? skinAccent : DS.Colors.overlayBackground)
                            .padding(.horizontal, DS.Spacing.xxxl + DS.Spacing.xxl + DS.Spacing.xs)
                            .padding(.vertical, DS.Spacing.lg)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.onOverlay)
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(skinAccent.opacity(dismissHovered ? 0.5 : 0), lineWidth: DS.Border.medium)
                            )
                            .shadow(color: DS.Colors.onOverlay.opacity(dismissHovered ? skin.hoverShadowOpacity * 1.5 : skin.shadowOpacity * 2), radius: dismissHovered ? skin.hoverShadowRadius : skin.shadowRadius, y: dismissHovered ? skin.hoverShadowY : skin.shadowY)
                            .scaleEffect(dismissHovered ? 1.03 : 1.0)
                            .animation(skin.resolvedMicroAnimation, value: dismissHovered)
                    }
                    .buttonStyle(.plain)
                    .onHover { dismissHovered = $0 }
                    .keyboardShortcut(event.meetingLink != nil ? .escape : .return, modifiers: [])
                    .accessibilityLabel("Dismiss alert")
                    .accessibilityHint(event.meetingLink != nil ? "Press Escape to dismiss" : "Press Enter to dismiss")
                }

                Text(event.meetingLink != nil ? "Enter to join \u{00B7} Esc to dismiss" : "Press Enter or Esc to dismiss")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.onOverlay.opacity(DS.Opacity.tertiaryText))
                    .accessibilityHidden(true)

                Spacer().frame(height: DS.Spacing.xxxl + DS.Spacing.xxl + DS.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // HIG: Handle Escape key without hidden zero-size button hack
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        } // TimelineView
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : (reduceMotion ? 1 : 0.92))
        .onAppear {
            Haptics.impact()
            if reduceMotion {
                isVisible = true
            } else {
                withAnimation(DS.Animation.smoothSpring) {
                    isVisible = true
                }
            }
        }
    }

    /// Countdown color: uses skin accent when plenty of time remains,
    /// falls back to urgency colors (warning/error) when imminent.
    private func countdownDisplayColor(_ secondsRemaining: Int) -> Color {
        if secondsRemaining <= 120 { return skin.resolvedDestructiveColor }
        if secondsRemaining <= 300 { return skin.resolvedWarningColor }
        return skinAccent
    }

    // MARK: - Bell Icon

    private var bellIcon: some View {
        Image(systemName: "bell.fill")
            .font(.system(size: DS.Size.alertIconSize))
            .foregroundStyle(
                LinearGradient(
                    colors: [skinAccent, skinSecondary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .shadow(color: skinAccent.opacity(0.5), radius: DS.Shadows.glowRadius)
            .symbolEffect(
                .bounce,
                options: reduceMotion ? .default : .repeating.speed(0.4),
                value: isVisible
            )
    }

    // MARK: - Countdown

    private func countdownText(_ secondsRemaining: Int) -> String {
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

    private func headerText(_ secondsRemaining: Int) -> String {
        if secondsRemaining <= 0 {
            return "Meeting started!"
        }
        return "Meeting in"
    }
}
