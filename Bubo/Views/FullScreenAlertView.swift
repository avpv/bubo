import SwiftUI

struct FullScreenAlertView: View {
    let event: CalendarEvent
    let minutesBefore: Int
    let onDismiss: () -> Void
    let onSnooze: (Int) -> Void
    /// J4: optional «Next» hint — surfaced quietly under the time row
    /// when there's a back-to-back event starting within ~10 min after
    /// the current one ends. Lets the user know «I have to be on time
    /// because something else is right behind this» before they tap
    /// Join. nil = no hint (no qualifying next event).
    var nextEvent: CalendarEvent? = nil

    /// J1: optional Join handler. When set, the «Join …» button +
    /// Return key call this instead of `onDismiss`, letting the host
    /// (`AppDelegate`) hand the alert off to a follow-up ribbon
    /// (`JoinRibbonView`) instead of vanishing entirely. nil = legacy
    /// behaviour: opening the URL and dismissing the alert in one
    /// gesture.
    var onJoin: ((URL) -> Void)? = nil

    @State private var isVisible = false
    @State private var joinHovered = false
    @State private var dismissHovered = false
    @FocusState private var isFocused: Bool
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

                // HIG: Use semantic text styles that scale with Dynamic Type.
                // Hero `display` step from the four-step ramp — fullscreen
                // alert is the only surface licensed to use it.
                Text(headerText(secondsRemaining))
                    .font(DS.Typography.display(skin: skin))
                    .foregroundStyle(DS.Colors.onOverlay)

                // Live countdown timer.
                //
                // Birman: «срочность — это не только цвет». Weight ramps from
                // `.regular` (calm, > 10 min) → `.medium` → `.semibold` (5 min
                // threshold) → `.bold` → `.heavy` (last minute). The user reads
                // urgency on a second channel that survives Reduce Motion +
                // Increased Contrast, where the red is desaturated and the
                // animation is stripped.
                //
                // Face: SF Pro Rounded with `monospacedDigit()` instead of the
                // monospaced design — the friendly Clock / Fitness countdown
                // face, but digits stay equal width so 1-Hz updates don't
                // shimmy. The weight transition is cross-faded.
                Text(countdownText(secondsRemaining))
                    .font(DS.Typography.heroCountdown(secondsRemaining: secondsRemaining))
                    .scaleEffect(1.5)
                    .foregroundStyle(countdownDisplayColor(secondsRemaining))
                    .shadow(color: countdownDisplayColor(secondsRemaining).opacity(0.5), radius: DS.Shadows.buttonRadius)
                    .contentTransition(.numericText())
                    .motionAwareAnimation(.linear(duration: 0.3), value: secondsRemaining, reduceMotion: reduceMotion)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4),
                               value: DS.Typography.countdownWeight(for: secondsRemaining))

                // Event title sits on the `headline` step (`.title3`) of the
                // four-step ramp — title2 / title were extra rungs that made
                // the alert read as «six sizes shouting at me».
                Text(event.title)
                    .font(DS.Typography.headline(skin: skin))
                    .foregroundStyle(DS.Colors.onOverlay)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Alert.titlePadding)

                HStack(spacing: DS.Spacing.xl) {
                    Label(event.formattedTimeRange, systemImage: "clock.fill")
                        .font(DS.Typography.body(skin: skin))
                        .foregroundStyle(DS.Colors.onOverlay.opacity(0.9))

                    if let location = event.location, !location.isEmpty {
                        Label(location, systemImage: "location.fill")
                            .font(DS.Typography.body(skin: skin))
                            .foregroundStyle(DS.Colors.onOverlay.opacity(0.9))
                    }
                }

                // J4: heads-up about the next back-to-back event.
                // Quiet single-line hint — the user is reading the
                // primary alert, this is a contextual aside, not a
                // second doménominate (§1).
                if let next = nextEvent {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "arrow.right.to.line.alt")
                            .font(.footnote)
                            .foregroundStyle(DS.Colors.onOverlay.opacity(DS.Opacity.tertiaryText))
                        Text("Next \u{00B7} \(next.title) at \(next.formattedTime)")
                            .font(.footnote)
                            .foregroundStyle(DS.Colors.onOverlay.opacity(DS.Opacity.tertiaryText))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .accessibilityLabel("Next event after this: \(next.title) at \(next.formattedTime)")
                }

                Spacer()

                // Action buttons — inline snooze for quick access
                VStack(spacing: DS.Spacing.xl) {
                    // Primary row: Join (if meeting) + Dismiss
                    HStack(spacing: DS.Spacing.xl) {
                        // Join meeting button — skin gradient fill
                        if let meetingURL = event.meetingLink, let serviceName = event.meetingServiceName {
                            Button {
                                Haptics.impact()
                                handleJoin(url: meetingURL)
                            } label: {
                                Label("Join \(serviceName)", systemImage: "video.fill")
                                    .font(DS.Typography.headline(skin: skin))
                                    .foregroundStyle(DS.contrastingForeground(for: skinAccent))
                                    .padding(.horizontal, DS.Alert.joinButtonPadding)
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
                                .font(DS.Typography.headline(skin: skin))
                                .foregroundStyle(dismissHovered ? skinAccent : DS.Colors.overlayBackground)
                                .padding(.horizontal, DS.Alert.dismissButtonPadding)
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
                    }

                    // Snooze row — adaptive to remaining time
                    if !adaptiveSnoozeOptions(secondsRemaining).isEmpty {
                        HStack(spacing: DS.Spacing.md) {
                            Text("Snooze for")
                                .font(DS.Typography.body(skin: skin, weight: .medium))
                                .foregroundStyle(DS.Colors.onOverlay.opacity(DS.Opacity.tertiaryText))

                            ForEach(adaptiveSnoozeOptions(secondsRemaining), id: \.self) { minutes in
                                Button {
                                    Haptics.tap()
                                    onSnooze(minutes)
                                } label: {
                                    Text(DS.formatMinutes(minutes))
                                        .font(DS.Typography.body(skin: skin))
                                        .foregroundStyle(DS.Colors.onOverlay)
                                        .padding(.horizontal, DS.Spacing.xl)
                                        .padding(.vertical, DS.Spacing.sm)
                                        .background(
                                            Capsule()
                                                .fill(DS.Materials.overlay)
                                        )
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(
                                                    skinAccent.opacity(DS.Opacity.subtleBorder),
                                                    lineWidth: DS.Border.thin
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Text(event.meetingLink != nil ? "Enter to join \u{00B7} Esc to dismiss" : "Press Enter or Esc to dismiss")
                    .font(.footnote)
                    .foregroundStyle(DS.Colors.onOverlay.opacity(DS.Opacity.tertiaryText))
                    .accessibilityHidden(true)

                Spacer().frame(height: DS.Alert.footerSpacer)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // HIG: Handle Escape key without hidden zero-size button hack
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onKeyPress(.return) {
            if let meetingURL = event.meetingLink {
                handleJoin(url: meetingURL)
            } else {
                onDismiss()
            }
            return .handled
        }
        .focusable()
        .focused($isFocused)
        } // TimelineView
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : (reduceMotion ? 1 : 0.92))
        .onAppear {
            Haptics.impact()
            isFocused = true
            if reduceMotion {
                isVisible = true
            } else {
                withAnimation(DS.Animation.smoothSpring) {
                    isVisible = true
                }
            }
        }
    }

    /// J1: routed Join handler. When the host wired `onJoin`, defer
    /// the meeting-URL open + dismiss orchestration to it (lets it
    /// show a follow-up ribbon). Falls back to the legacy «open +
    /// dismiss» flow when no handler is provided so callers that
    /// haven't been migrated still work.
    private func handleJoin(url: URL) {
        if let onJoin {
            onJoin(url)
        } else {
            NSWorkspace.shared.open(url)
            onDismiss()
        }
    }

    /// Snooze options adapted to how much time remains before the event starts.
    /// Shows shorter intervals when time is tight, longer ones when there's plenty of room.
    private func adaptiveSnoozeOptions(_ secondsRemaining: Int) -> [Int] {
        let minutesLeft = secondsRemaining / 60
        if minutesLeft <= 0 { return [] } // event already started
        if minutesLeft <= 3 { return [1, 2] }
        if minutesLeft <= 7 { return [2, 5] }
        if minutesLeft <= 15 { return [5, 10] }
        if minutesLeft <= 30 { return [5, 10, 15] }
        return [10, 20, 30]
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
            return "Started!"
        }
        return "Starts in"
    }
}
