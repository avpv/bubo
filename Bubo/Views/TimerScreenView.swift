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
    /// Scrub-the-ring callback: adjusts the active event's `endDate`
    /// by a signed minute delta (positive = extend, negative = shorten).
    /// `MenuBarView` clamps the resulting `endDate` so it never drops
    /// below «now + 1 minute», preventing the timer from auto-ending
    /// while the user is dragging. Pass nil to disable scrubbing.
    var onAdjustEndDate: ((CalendarEvent, Int) -> Void)? = nil

    /// J9: pause-the-ring callback. Shifts BOTH `startDate` and
    /// `endDate` forward by the given minute delta (always positive
    /// from the gesture path), effectively «pausing» the Pomodoro by
    /// the dragged amount — the work segment resumes from where it
    /// was, just N minutes later in wall time. Pass nil to disable
    /// the gesture entirely.
    var onShiftSchedule: ((CalendarEvent, Int) -> Void)? = nil

    var wallpaper: WallpaperDefinition = WallpaperCatalog.none
    var customPhotoPath: String = ""
    var customPhotoOpacity: Double = 0.25
    var customPhotoBlur: Double = 2


    @State private var pulseRing = false
    @State private var appearedAt: Date?

    /// Scrub state. A horizontal drag on the ring adjusts the event's
    /// `endDate` in 1-minute snaps, with `Haptics.alignment()` on every
    /// snap boundary. `scrubArmed` toggles the visual cue (a tinted
    /// ring + delta badge); `scrubMinuteDelta` is the live signed delta
    /// the gesture has accumulated since press-start.
    @State private var scrubArmed = false
    @State private var scrubMinuteDelta = 0
    @State private var scrubLastSnap = 0

    /// J9: vertical-drag axis lock. Set on the first `.onChanged` of a
    /// drag, cleared on `.onEnded`. Lets us route subsequent updates
    /// to either the existing horizontal scrub (endDate only) or the
    /// new pause path (start + end together) without flickering between
    /// the two as the user's drag wobbles. `pauseMinuteDelta` mirrors
    /// `scrubMinuteDelta` for the pause path; only positive values
    /// are accepted (drag-down = pause, drag-up doesn't unpause —
    /// undo via toast or scrub-back-with-horizontal).
    @State private var dragAxisLocked = false
    @State private var dragAxisIsVertical = false
    @State private var pauseMinuteDelta = 0
    @State private var pauseLastSnap = 0

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
            withAnimation(DS.Animation.pulseSlow().repeatForever(autoreverses: true)) {
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

                        // Center content. Status label is the same quiet
                        // subhead as `sectionHeaderStyle()` — mixed case, no
                        // tracking, just `.footnote.semibold`. Birman: «one
                        // subhead for the whole app»; cap-height + letter
                        // spacing made this read like 1990s product chrome.
                        VStack(spacing: DS.Spacing.sm) {
                            Text(statusLabel(now))
                                .sectionHeaderStyle()
                                .foregroundStyle(skin.resolvedTextTertiary)

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
                    .scaleEffect(scrubArmed ? 1.03 : 1.0)
                    .animation(skin.resolvedMicroAnimation, value: scrubArmed)
                    // Horizontal drag on the ring extends or shortens the
                    // active event's `endDate`. The gesture is masked when
                    // the event isn't currently in progress (no «remaining
                    // time» to scrub then) or when it isn't a local
                    // standard event (pomodoros own a structured phase
                    // model that isn't a simple end-date adjustment).
                    .gesture(scrubGesture(now: now),
                             including: canScrub(now: now) ? .gesture : .none)
                    .overlay(scrubBadge.padding(.top, DS.Size.timerRingDiameter * 0.55))
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
                                            .fill(idx < done ? skin.accentColor : skin.resolvedTextTertiary.opacity(DS.Opacity.softAccent))
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

                        // Focus-burst subtitle: the task tied to the
                        // current work round, so the user always sees
                        // "what I'm actually doing right now" even when
                        // the main title is a compound "A + B + C".
                        if let currentTask = currentBurstTask(now: now) {
                            HStack(spacing: DS.Spacing.xs) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: DS.Size.iconSmall))
                                    .foregroundStyle(skin.accentColor)
                                Text(currentTask.title)
                                    .font(.system(.subheadline, design: skin.resolvedFontDesign, weight: .medium))
                                    .foregroundStyle(skin.resolvedTextPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }

                        HStack(spacing: DS.Spacing.md) {
                            Label(event.formattedDate, systemImage: "calendar")
                                .font(.footnote)
                                .foregroundStyle(skin.resolvedTextSecondary)

                            Label(event.formattedTimeRange, systemImage: "clock")
                                .font(.footnote)
                                .foregroundStyle(skin.resolvedTextSecondary)
                        }

                        if let location = event.location, !location.isEmpty {
                            Label(location, systemImage: "location.fill")
                                .font(.footnote)
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
                                        .font(.footnote.weight(.medium))
                                }
                                .buttonStyle(.action(role: .primary, size: .compact))

                                if let onScheduleNext {
                                    Button {
                                        Haptics.tap()
                                        onScheduleNext(event)
                                    } label: {
                                        Label("Plan Next", systemImage: "wand.and.stars")
                                            .font(.footnote.weight(.medium))
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

    // MARK: - Scrub-the-Ring (adjust event end-date by horizontal drag)

    /// Pixel-to-minute conversion for ring-scrubbing. 8pt of horizontal
    /// drag = 1 minute, so a comfortable cross-ring sweep (~180pt) covers
    /// roughly 22 minutes — enough to «add another quick chunk» without
    /// being so sensitive that small wrist twitches change the time.
    private var scrubPointsPerMinute: CGFloat { 8.0 }

    /// Hard cap so a single scrub gesture can extend by at most one hour
    /// or shorten by however much the event has remaining (the commit
    /// path clamps end-date against «now + 60s» as a final safety net).
    private var maxScrubMinutes: Int { 60 }

    private func canScrub(now: Date) -> Bool {
        // Either path needs at least one of the two callbacks wired —
        // the gesture composes both axes into one DragGesture, then
        // routes per-axis once the user picks a direction.
        guard onAdjustEndDate != nil || onShiftSchedule != nil else { return false }
        return event.isLocalEvent
            && !event.isRecurring
            && (event.eventType == .standard || event.eventType == .pomodoro)
            && isInProgress(now)
    }

    /// J9: drag-down threshold (in points) before the vertical pause
    /// path is considered a deliberate gesture. Higher than the 6pt
    /// horizontal threshold because a vertical wobble is more common
    /// than a vertical commit.
    private var pausePointsPerMinute: CGFloat { 8.0 }

    /// Cap on a single pause gesture — same hour-long window as the
    /// horizontal scrub, expressed positive-only.
    private var maxPauseMinutes: Int { 60 }

    private func scrubGesture(now: Date) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                // Lock the axis on the first frame of the gesture —
                // whichever delta is larger wins. Stops mid-drag
                // wobble from flickering between the two paths.
                if !dragAxisLocked {
                    dragAxisLocked = true
                    dragAxisIsVertical = abs(value.translation.height) > abs(value.translation.width)
                    scrubArmed = true
                    Haptics.impact()
                }

                if dragAxisIsVertical, onShiftSchedule != nil {
                    // J9 path: drag-down only (positive translation.height
                    // means cursor moved DOWN in SwiftUI). Drag-up returns
                    // a negative value and we floor at 0 — the ring
                    // doesn't «un-pause» retroactively.
                    let raw = Int((value.translation.height / pausePointsPerMinute).rounded())
                    let clamped = max(0, min(maxPauseMinutes, raw))
                    if clamped != pauseLastSnap {
                        Haptics.alignment()
                        pauseLastSnap = clamped
                    }
                    pauseMinuteDelta = clamped
                } else if onAdjustEndDate != nil {
                    // Horizontal scrub — extend / shorten endDate.
                    let raw = Int((value.translation.width / scrubPointsPerMinute).rounded())
                    let clamped = max(-maxScrubMinutes, min(maxScrubMinutes, raw))
                    if clamped != scrubLastSnap {
                        Haptics.alignment()
                        scrubLastSnap = clamped
                    }
                    scrubMinuteDelta = clamped
                }
            }
            .onEnded { _ in
                if dragAxisIsVertical {
                    if pauseMinuteDelta > 0 {
                        onShiftSchedule?(event, pauseMinuteDelta)
                        Haptics.impact()
                    }
                } else if scrubMinuteDelta != 0 {
                    onAdjustEndDate?(event, scrubMinuteDelta)
                    Haptics.impact()
                }
                withAnimation(skin.resolvedMicroAnimation) {
                    scrubArmed = false
                }
                scrubMinuteDelta = 0
                scrubLastSnap = 0
                pauseMinuteDelta = 0
                pauseLastSnap = 0
                dragAxisLocked = false
                dragAxisIsVertical = false
            }
    }

    /// Floating capsule under the ring showing the proposed end-time
    /// shift while a scrub is in flight. Same visual recipe as the
    /// drag-to-reschedule badge in `EventRowView` — glass capsule, accent
    /// border, z2 elevation — so the two gestures read as a family.
    @ViewBuilder
    private var scrubBadge: some View {
        if scrubArmed {
            // Two voices on one badge: «+5 min» (horizontal scrub →
            // end-date extend) vs «Pause +5 min» (vertical drag →
            // shift the whole window). The verb prefix on the pause
            // path tells the user the gesture is doing something
            // structurally different from scrub.
            let label: String = {
                if dragAxisIsVertical {
                    if pauseMinuteDelta == 0 { return "Pause \u{2014}" }
                    return "Pause +\(pauseMinuteDelta)\u{00A0}min"
                } else {
                    if scrubMinuteDelta == 0 { return "\u{2014}" }
                    return scrubMinuteDelta > 0 ? "+\(scrubMinuteDelta)\u{00A0}min" : "\(scrubMinuteDelta)\u{00A0}min"
                }
            }()
            Text(label)
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(skin.accentColor)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .background(skin.resolvedPlatterMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(skin.accentColor.opacity(DS.Opacity.softAccent),
                                                 lineWidth: DS.Border.thin))
                .elevation(.z2, skin: skin)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .accessibilityLabel(dragAxisIsVertical
                    ? "Pause Pomodoro by \(pauseMinuteDelta)\u{00A0}minutes"
                    : "Adjust end time \(label)")
        }
    }

    // MARK: - Subviews

    /// Hero ring digits use SF Pro Rounded with `monospacedDigit()` (the
    /// «friendly» Clock / Fitness face) instead of the `.monospaced` system
    /// design — same equal-width digit guarantee, but the glyph shapes match
    /// the rest of the popover instead of the slab-feel of SF Mono.
    private func timerRow(_ components: [TimeComponent], size: CGFloat) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(components, id: \.id) { comp in
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(comp.value)
                        .font(DS.Typography.heroRingDigit(size: size))
                        .foregroundStyle(skin.resolvedTextPrimary)
                        .contentTransition(.numericText())
                    Text(comp.unit)
                        .font(DS.Typography.heroRingUnit(size: size, design: skin.resolvedFontDesign))
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
            }
        }
    }

    // MARK: - Focus Burst

    /// Task tied to the current work round in a focus-burst session.
    /// Returns `nil` when the event has no task sequence, the timer is
    /// in a break / long break / done phase, or the round index is out
    /// of bounds of the sequence (the resolver caps rounds to pack
    /// size, but a stale persisted event could have a mismatch).
    private func currentBurstTask(now: Date) -> CalendarEvent.TaskSequenceEntry? {
        guard !event.pomodoroTaskSequence.isEmpty else { return nil }
        guard let phase = currentPhase(now) else { return nil }
        guard case .work(let round, _) = phase.kind else { return nil }
        let idx = round - 1
        guard event.pomodoroTaskSequence.indices.contains(idx) else { return nil }
        return event.pomodoroTaskSequence[idx]
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
