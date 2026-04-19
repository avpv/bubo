import SwiftUI

struct TimerScreenView: View {
    @Environment(\.activeSkin) private var skin
    let event: CalendarEvent
    var onBack: () -> Void
    var isPinned: Bool = false
    var onRepeat: ((CalendarEvent) -> Void)? = nil
    var onScheduleNext: ((CalendarEvent) -> Void)? = nil
    /// Called once when the view goes away, if the event had a pomodoro
    /// shape. Lets `MenuBarView` route the outcome into
    /// `PomodoroHistoryService` without pulling the service into a view.
    var onSessionEnded: ((PomodoroHistoryEntry) -> Void)? = nil

    var wallpaper: WallpaperDefinition = WallpaperCatalog.none
    var customPhotoPath: String = ""
    var customPhotoOpacity: Double = 0.25
    var customPhotoBlur: Double = 2


    @State private var pulseRing = false
    @State private var appearedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.navigateHome) private var navigateHome

    private var totalDuration: TimeInterval {
        event.endDate.timeIntervalSince(event.startDate)
    }

    private func secondsUntilStart(_ now: Date) -> Int {
        max(Int(event.startDate.timeIntervalSince(now)), 0)
    }

    private func secondsUntilEnd(_ now: Date) -> Int {
        max(Int(event.endDate.timeIntervalSince(now)), 0)
    }

    private func isInProgress(_ now: Date) -> Bool {
        secondsUntilStart(now) <= 0 && secondsUntilEnd(now) > 0
    }

    private func hasEnded(_ now: Date) -> Bool {
        secondsUntilStart(now) <= 0 && secondsUntilEnd(now) <= 0
    }

    private func activeSeconds(_ now: Date) -> Int {
        if let phase = currentPhase(now), isInProgress(now) {
            return max(0, Int(phase.phaseEnd.timeIntervalSince(now)))
        }
        return isInProgress(now) ? secondsUntilEnd(now) : secondsUntilStart(now)
    }

    private func ringProgress(_ now: Date) -> Double {
        if hasEnded(now) { return 1.0 }
        if let phase = currentPhase(now), isInProgress(now) {
            let total = phase.duration
            guard total > 0 else { return 0 }
            let elapsed = total - phase.phaseEnd.timeIntervalSince(now)
            return min(max(elapsed / total, 0), 1.0)
        }
        if isInProgress(now) {
            guard totalDuration > 0 else { return 0 }
            let elapsed = totalDuration - Double(secondsUntilEnd(now))
            return min(elapsed / totalDuration, 1.0)
        }
        let cap = 86400.0
        let clamped = min(Double(secondsUntilStart(now)), cap)
        return clamped / cap
    }

    /// Active pomodoro phase for `now`, or `nil` when the event has no
    /// `pomodoroConfig` (recurrence-based pomodoros and plain events
    /// keep the legacy single-countdown behaviour).
    private func currentPhase(_ now: Date) -> CalendarEvent.PomodoroPhase? {
        event.currentPomodoroPhase(at: now)
    }

    private func accentColor(_ now: Date) -> Color {
        if hasEnded(now) { return skin.resolvedTextTertiary }
        if isInProgress(now) { return DS.Colors.accent }
        return DS.urgencyColor(minutesUntil: secondsUntilStart(now) / 60, skin: skin)
    }

    var body: some View {
        // HIG: Use TimelineView for time-based UI updates
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            ZStack {
                if isPinned {
                    AppBackgroundLayer(
                        skin: skin,
                        wallpaper: wallpaper,
                        customPhotoPath: customPhotoPath,
                        customPhotoOpacity: customPhotoOpacity,
                        customPhotoBlur: customPhotoBlur
                    )
                }

                timerContent(now: now)
            }
            .frame(width: DS.Popover.width, height: DS.Popover.timerHeight)
        }
        .onAppear {
            appearedAt = Date()
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                pulseRing = true
            }
        }
        .onDisappear { reportSessionOutcome() }
    }

    /// Record the session outcome using the phase model so the history
    /// reflects what actually happened: `completedRounds` comes from the
    /// pomodoro phase at exit time (not an on-screen-time heuristic).
    /// A session counts as completed when every work round finished.
    private func reportSessionOutcome() {
        guard
            let config = event.pomodoroConfig,
            let onSessionEnded
        else { return }

        let now = Date()
        // Minutes actually elapsed inside the session (clamped to the
        // event window). For a session that hasn't started yet nothing
        // is recorded.
        let sessionElapsed = now.timeIntervalSince(event.startDate)
        guard sessionElapsed > 0 else { return }

        let actualMinutes = max(
            0,
            Int(min(sessionElapsed, totalDuration) / 60)
        )
        let phase = event.currentPomodoroPhase(at: now)
        let completedRounds = phase?.completedRounds ?? 0
        let completed = completedRounds >= config.rounds
        let cal = Calendar.current
        let entry = PomodoroHistoryEntry(
            startedAt: event.startDate,
            startHour: cal.component(.hour, from: event.startDate),
            config: config,
            actualMinutes: actualMinutes,
            completed: completed
        )
        onSessionEnded(entry)
    }

    private func timerContent(now: Date) -> some View {
        let accent = accentColor(now)
        let ended = hasEnded(now)
        let progress = ringProgress(now)
        let components = timeComponents(now)
        let days = hasDays(now)

        return VStack(spacing: 0) {
            PopoverHeader(
                title: "Timer",
                showBack: !isPinned,
                onBack: onBack,
                trailing: AnyView(
                    HStack(spacing: DS.Spacing.sm) {
                    if !isPinned {
                        Button {
                            Haptics.tap()
                            navigateHome?()
                        } label: {
                            Text("Done")
                                .font(.system(size: DS.Size.iconMedium, weight: .medium))
                                .foregroundStyle(skin.accentColor)
                        }
                        .buttonStyle(.borderless)
                        .help("Return to event list")
                    }
                    Button {
                        Haptics.tap()
                        if isPinned {
                            NotificationCenter.default.post(name: .unpinTimerWindow, object: nil)
                        } else {
                            let popover = NSApp.keyWindow
                            popover?.close()
                            NotificationCenter.default.post(
                                name: .pinTimerWindow,
                                object: nil,
                                userInfo: ["event": event]
                            )
                        }
                    } label: {
                        Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.fill" : "pin")
                            .font(.system(size: DS.Size.iconMedium, weight: .medium))
                            .foregroundStyle(isPinned ? DS.Colors.accent : skin.resolvedTextSecondary)
                    }
                    .buttonStyle(.borderless)
                    .help(isPinned ? "Unpin window" : "Pin on top")
                    .accessibilityLabel(isPinned ? "Unpin timer window" : "Pin timer window on top")
                    })
            )

            ScrollView {
                VStack(spacing: DS.Spacing.xl) {
                    // Timer ring
                    ZStack {
                        // Track — HIG: adapt opacity for Increase Contrast mode
                        Circle()
                            .stroke(accent.opacity(contrast == .increased ? skin.hoverFillOpacity * 4 : skin.hoverFillOpacity * 1.5), lineWidth: DS.Size.timerRingStrokeWidth)
                            .frame(width: DS.Size.timerRingDiameter, height: DS.Size.timerRingDiameter)

                        // Progress arc
                        if !ended {
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(
                                    accent,
                                    style: StrokeStyle(lineWidth: DS.Size.timerRingStrokeWidth, lineCap: .round)
                                )
                                .frame(width: DS.Size.timerRingDiameter, height: DS.Size.timerRingDiameter)
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 1), value: progress)
                        }

                        // Subtle glow — hidden in Increase Contrast to reduce visual noise
                        if contrast != .increased {
                            Circle()
                                .fill(accent.opacity(pulseRing ? 0.06 : 0.02))
                                .frame(width: DS.Size.timerRingDiameter - 10, height: DS.Size.timerRingDiameter - 10)
                                .blur(radius: 20)
                        }

                        // Center content
                        VStack(spacing: DS.Spacing.sm) {
                            Text(statusLabel(now))
                                .font(.system(.caption, design: skin.resolvedFontDesign, weight: .medium))
                                .foregroundStyle(skin.resolvedTextTertiary)
                                .textCase(.uppercase)
                                .tracking(1.5)

                            if ended {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: DS.Size.timerCheckmarkSize, weight: .light))
                                    .foregroundStyle(skin.resolvedTextTertiary)
                            } else if days {
                                VStack(spacing: DS.Spacing.xxs) {
                                    timerRow(Array(components.prefix(2)), size: 28)
                                    timerRow(Array(components.suffix(2)), size: 28)
                                }
                            } else {
                                timerRow(components, size: 32)
                            }
                        }
                    }
                    .staggeredEntrance(index: 0)

                    // Pomodoro segment indicator — round number and work/break status.
                    // Prefers the pomodoroConfig-driven phase for single-event
                    // sessions; falls back to the id-suffix path used by
                    // recurrence-expanded pomodoros.
                    if let display = pomodoroDisplayInfo(now: now) {
                        VStack(spacing: DS.Spacing.sm) {
                            HStack(spacing: DS.Spacing.sm) {
                                Image(systemName: display.segment.iconName)
                                    .font(.system(size: DS.Size.iconMedium, weight: .medium))
                                    .foregroundStyle(pomodoroSegmentColor(display.segment))

                                Text(display.segment.label)
                                    .font(.system(.subheadline, design: skin.resolvedFontDesign, weight: .semibold))
                                    .foregroundStyle(pomodoroSegmentColor(display.segment))

                                if let round = display.round, let total = display.total {
                                    Text("·")
                                        .foregroundStyle(skin.resolvedTextTertiary)
                                    Text("Round \(round) of \(total)")
                                        .font(.system(.subheadline, design: skin.resolvedFontDesign, weight: .medium))
                                        .foregroundStyle(skin.resolvedTextSecondary)
                                }
                            }
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.vertical, DS.Spacing.sm)
                            .adaptiveBadgeFill(pomodoroSegmentColor(display.segment))
                            .clipShape(Capsule())

                            // Round progress dots — visible only when we know
                            // the total (i.e. pomodoroConfig path).
                            if let total = display.total, let done = display.completed {
                                HStack(spacing: DS.Spacing.xs) {
                                    ForEach(0..<total, id: \.self) { idx in
                                        Circle()
                                            .fill(idx < done ? skin.accentColor : skin.resolvedTextTertiary.opacity(0.3))
                                            .frame(width: DS.Size.iconSmall / 2, height: DS.Size.iconSmall / 2)
                                    }
                                }
                                .accessibilityLabel("Completed \(done) of \(total) rounds")
                            }
                        }
                        .staggeredEntrance(index: 1)
                    }

                    // Event info card
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        Text(event.title)
                            .font(.system(.headline, design: skin.resolvedFontDesign, weight: .semibold))
                            .lineLimit(2)
                            .truncationMode(.tail)

                        HStack(spacing: DS.Spacing.md) {
                            Label(event.formattedDate, systemImage: "calendar")
                                .font(.caption)
                                .foregroundStyle(skin.resolvedTextSecondary)

                            Label(event.formattedTimeRange, systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(skin.resolvedTextSecondary)
                        }

                        if let location = event.location, !location.isEmpty {
                            Label(location, systemImage: "location.fill")
                                .font(.caption)
                                .foregroundStyle(skin.resolvedTextSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        // Post-session actions for Pomodoro
                        if ended, event.eventType == .pomodoro {
                            HStack(spacing: DS.Spacing.sm) {
                                Button {
                                    Haptics.tap()
                                    onRepeat?(event)
                                } label: {
                                    Label("Repeat", systemImage: "arrow.counterclockwise")
                                        .font(.caption.weight(.medium))
                                }
                                .buttonStyle(.action(role: .primary, size: .compact))

                                if let onScheduleNext {
                                    Button {
                                        Haptics.tap()
                                        onScheduleNext(event)
                                    } label: {
                                        Label("Plan Next", systemImage: "wand.and.stars")
                                            .font(.caption.weight(.medium))
                                    }
                                    .buttonStyle(.action(role: .secondary, size: .compact))
                                }
                            }
                            .padding(.top, DS.Spacing.sm)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.lg)
                    .skinPlatter(skin)
                    .skinPlatterDepth(skin)
                    .staggeredEntrance(index: event.pomodoroSegment != nil ? 2 : 1)
                }
                .padding(.horizontal, DS.Spacing.xl)
                .padding(.top, DS.Spacing.lg)
                .padding(.bottom, DS.Spacing.xl)
            }
        }
    }

    // MARK: - Subviews

    private func timerRow(_ components: [TimeComponent], size: CGFloat) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(components, id: \.id) { comp in
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(comp.value)
                        .font(.system(size: size, weight: .bold, design: .monospaced))
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .contentTransition(.numericText())
                    Text(comp.unit)
                        .font(.system(size: size * 0.45, weight: .medium, design: skin.resolvedFontDesign))
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
            }
        }
    }

    // MARK: - Pomodoro Display

    /// Segment + optional round / total / completed tuple for the header
    /// capsule and the rounds-dots indicator.
    private struct PomodoroDisplayInfo {
        let segment: CalendarEvent.PomodoroSegment
        let round: Int?
        let total: Int?
        /// Rounds fully finished by `now`. Non-nil only on the
        /// pomodoroConfig path, where we can compute it deterministically.
        let completed: Int?
    }

    private func pomodoroDisplayInfo(now: Date) -> PomodoroDisplayInfo? {
        if let phase = currentPhase(now) {
            switch phase.kind {
            case .work(let round, let total):
                return PomodoroDisplayInfo(
                    segment: .work, round: round, total: total,
                    completed: phase.completedRounds
                )
            case .shortBreak(let afterRound):
                return PomodoroDisplayInfo(
                    segment: .shortBreak, round: afterRound, total: phase.totalRounds,
                    completed: phase.completedRounds
                )
            case .longBreak:
                return PomodoroDisplayInfo(
                    segment: .longBreak, round: nil, total: phase.totalRounds,
                    completed: phase.completedRounds
                )
            case .done:
                return nil
            }
        }
        guard let segment = event.pomodoroSegment else { return nil }
        return PomodoroDisplayInfo(
            segment: segment,
            round: event.pomodoroRoundNumber,
            total: event.pomodoroTotalRounds,
            completed: nil
        )
    }

    // MARK: - Pomodoro Colors

    private func pomodoroSegmentColor(_ segment: CalendarEvent.PomodoroSegment) -> Color {
        switch segment {
        case .work: skin.accentColor
        case .shortBreak: skin.resolvedSuccessColor
        case .longBreak: DS.Colors.info
        }
    }

    // MARK: - Helpers

    private func statusLabel(_ now: Date) -> String {
        if hasEnded(now) { return "Ended" }
        if isInProgress(now), let phase = currentPhase(now) {
            switch phase.kind {
            case .work(let round, let total): return "Work \(round) / \(total)"
            case .shortBreak:                 return "Break"
            case .longBreak:                  return "Long break"
            case .done:                       return "Ended"
            }
        }
        if isInProgress(now) { return "Ends in" }
        return "Starts in"
    }

    private func hasDays(_ now: Date) -> Bool {
        activeSeconds(now) >= 86400
    }

    private struct TimeComponent: Identifiable {
        let id: String
        let value: String
        let unit: String
    }

    private func timeComponents(_ now: Date) -> [TimeComponent] {
        let total = activeSeconds(now)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        var result: [TimeComponent] = []
        if days > 0 {
            result.append(TimeComponent(id: "d", value: "\(days)", unit: "d"))
        }
        if days > 0 || hours > 0 {
            result.append(TimeComponent(id: "h", value: "\(hours)", unit: "h"))
        }
        result.append(TimeComponent(id: "m", value: String(format: "%02d", minutes), unit: "m"))
        result.append(TimeComponent(id: "s", value: String(format: "%02d", seconds), unit: "s"))
        return result
    }
}
