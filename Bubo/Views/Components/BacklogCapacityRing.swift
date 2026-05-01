import SwiftUI

// MARK: - Capacity Ring

/// Small ring that compares today's remaining working minutes against the
/// total duration still in the backlog. One visual channel — colour —
/// carries the answer: green = fits, orange = tight (≤ 120%),
/// red = overflow. Empty backlog = full green ring (nothing at risk).
///
/// Birman: одно кольцо даёт больше, чем таблица цифр.
struct BacklogCapacityRing: View {
    let pendingMinutes: Int
    let remainingWorkdayMinutes: Int
    var optimizerService: OptimizerService

    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPopoverPresented = false
    @State private var isHovered = false
    /// Flips to true once `.onAppear` fires. Drives the entrance draw —
    /// the ring strokes from 0 to the current fraction over ~0.4s the
    /// first time the view enters the hierarchy, instead of snapping into
    /// place. Subsequent fraction changes still animate via `.animation`
    /// below; this state only gates the very first frame.
    @State private var hasAppeared = false

    /// Ratio of workload to available time. Guards against division-by-zero
    /// when the workday is over (remaining = 0): in that case, any workload
    /// is overflow; an empty backlog still reads as "fine" (returns 0).
    private var fraction: Double {
        BacklogLogic.capacityFraction(
            pendingMinutes: pendingMinutes,
            remainingWorkdayMinutes: remainingWorkdayMinutes
        )
    }

    /// Trim end-point that the ring actually renders. Stays at 0 until
    /// `.onAppear` flips `hasAppeared`, then snaps (under `reduceMotion`)
    /// or eases (otherwise) to the live fraction. Clamped at 0.05 so an
    /// empty/tiny backlog still leaves a visible nub on the ring.
    private var displayedTrim: Double {
        guard hasAppeared else { return 0 }
        return min(max(fraction, 0.05), 1.0)
    }

    private var color: Color {
        Self.ringColor(for: fraction, skin: skin)
    }

    /// Four-step capacity palette. Dark skins swap the plain `.orange` /
    /// `.green` system colors for slightly lighter, higher-chroma shades —
    /// the defaults sit too close in luminance to common dark glass fills,
    /// and the 2pt ring stroke disappears against certain Material
    /// backgrounds. Extracted so the same resolution is reachable from
    /// tests without instantiating the view.
    static func ringColor(for fraction: Double, skin: SkinDefinition) -> Color {
        let isDark = skin.prefersDarkTint
        switch fraction {
        case ..<0.8:
            return isDark
                ? Color(red: 0.35, green: 0.85, blue: 0.55) // mint, WCAG-ish vs dark glass
                : .green
        case ..<1.0:
            return skin.accentColor
        case ..<1.2:
            return isDark
                ? Color(red: 1.00, green: 0.72, blue: 0.18) // amber — higher luminance than system .orange
                : .orange
        default:
            return skin.resolvedDestructiveColor
        }
    }

    /// Short status phrase that matches the ring colour. Used both in the
    /// popover header and in the `.help` tooltip so the meaning of the
    /// coloured ring is never a guess.
    private var statusLabel: String {
        switch fraction {
        case ..<0.8: return "Fits comfortably"
        case ..<1.0: return "On track"
        case ..<1.2: return "Tight fit"
        default:     return "Over capacity"
        }
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            ZStack {
                Circle()
                    .stroke(skin.resolvedTextTertiary.opacity(isHovered ? 0.45 : 0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: displayedTrim)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // Smooth runtime fraction changes too — adding a task,
                    // completing one, editing duration. Без этого кольцо
                    // прыгало мгновенно при каждом mutation.
                    .animation(
                        reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.3),
                        value: displayedTrim
                    )
            }
            .frame(width: 14, height: 14)
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            // Entrance draw: 0 → fraction over ~0.4s the first time the
            // ring shows up. `withAnimation` here animates the change in
            // `hasAppeared`, which `displayedTrim` reads. Reduce Motion
            // skips the easing — the value snaps in place.
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.easeOut(duration: 0.4)) {
                    hasAppeared = true
                }
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel("Backlog capacity")
        .accessibilityValue("\(Int(fraction * 100)) percent of remaining workday")
        .accessibilityHint("Shows capacity details and adjusts working hours and working days")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            BacklogCapacityPopover(
                pendingMinutes: pendingMinutes,
                remainingWorkdayMinutes: remainingWorkdayMinutes,
                fraction: fraction,
                color: color,
                statusLabel: statusLabel,
                optimizerService: optimizerService
            )
        }
    }
}

/// Detail popover revealed by tapping the capacity ring. Shows the raw
/// numbers behind the glyph and lets the user retune the working-hours
/// window in place — the same knobs as Settings → Optimizer, but one
/// click away at the moment the ring first catches their eye.
///
/// Birman: «если пользователю интересно — дайте, где, а не куда».
struct BacklogCapacityPopover: View {
    let pendingMinutes: Int
    let remainingWorkdayMinutes: Int
    let fraction: Double
    let color: Color
    let statusLabel: String
    var optimizerService: OptimizerService

    @Environment(\.activeSkin) private var skin

    private var percentText: String {
        // Past the 150% sentinel we just say ">150%" rather than scream a
        // nonsense number when the workday is already over.
        guard remainingWorkdayMinutes > 0 else { return ">100%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    var body: some View {
        @Bindable var service = optimizerService

        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            // Header: status + percentage. The colored dot mirrors the ring
            // so the popover obviously belongs to the glyph that opened it.
            HStack(spacing: DS.Spacing.sm) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextPrimary)
                Spacer(minLength: DS.Spacing.sm)
                Text(percentText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(skin.resolvedTextSecondary)
            }

            // Numbers behind the ring. Two rows — workload vs. remaining —
            // so users can see which side is driving the colour.
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                capacityRow(
                    label: "Backlog workload",
                    value: DS.formatMinutes(pendingMinutes)
                )
                capacityRow(
                    label: "Remaining today",
                    value: remainingWorkdayMinutes > 0
                        ? DS.formatMinutes(remainingWorkdayMinutes)
                        : "Workday ended"
                )
            }

            SkinSeparator()

            // Inline configuration. The pickers and the working-days
            // picker are *global* planning preferences — they affect
            // every planning surface, not just the backlog. The ring
            // is the most visible consequence and the place the user
            // notices the issue first, which earns them a shortcut
            // here instead of a detour through Settings → Assistant.
            // The scope caption below makes the global reach explicit
            // so nobody thinks they're tweaking a backlog-only knob.
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Workday")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextSecondary)

                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                    Text("Hours")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .frame(width: 60, alignment: .leading)
                    Picker("Start", selection: $service.workingHoursStart) {
                        ForEach(0...23, id: \.self) { hour in
                            Text("\(hour):00").tag(hour)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 80)

                    Text("\u{2013}")
                        .foregroundStyle(skin.resolvedTextTertiary)

                    Picker("End", selection: $service.workingHoursEnd) {
                        ForEach(0...23, id: \.self) { hour in
                            Text("\(hour):00").tag(hour)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }

                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("Days")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextSecondary)
                    WorkingDaysPicker(selection: $service.workingDays)
                }

                Text("Applies to all planning — also in Settings › Optimizer.")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.Spacing.xxs)
            }
        }
        .padding(DS.Spacing.lg)
        .frame(width: 320)
    }

    @ViewBuilder
    private func capacityRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
            Spacer(minLength: DS.Spacing.sm)
            Text(value)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(skin.resolvedTextPrimary)
        }
    }
}

// MARK: - Capacity Label

/// Compact textual companion to `BacklogCapacityRing`. Answers «успеешь
/// ли?» in plain language instead of presenting raw `pending / remaining`
/// numbers — «Done by 17:30», «1h over», «After hours · 3h queued».
///
/// Why the rephrase: the ring already carries the alarm via colour, and
/// the old «5h / 3h» label asked the reader to do the subtraction
/// themselves. The new label collapses that arithmetic into a verdict —
/// either you finish, or you spill, or the window's closed. Raw numbers
/// stay reachable through the ring's popover (one click) and the tooltip
/// for users who want them.
///
/// Birman: «информация — это интерпретация, не сырые данные». HIG: glanceable
/// status uses words a user already thinks in. Color stays neutral; the
/// ring carries the urgency channel.
///
/// `TimelineView(.everyMinute)` keeps the projected ETA from going stale
/// while the popover sits open — a 30-minute review session shouldn't
/// show a finish time computed at hour zero.
struct BacklogCapacityLabel: View {
    let pendingMinutes: Int
    /// Count of tasks that don't fit in the remaining workday. Used to
    /// surface the suffix «· N don't fit» next to the verdict so the reader
    /// gets the count without doing arithmetic. Pass 0 when nothing
    /// overflows; the suffix collapses on its own.
    var overflowingCount: Int = 0
    var optimizerService: OptimizerService

    @Environment(\.activeSkin) private var skin

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let forecast = BacklogLogic.capacityForecast(
                pendingMinutes: pendingMinutes,
                workingHours: optimizerService.workingHours,
                workingDays: optimizerService.workingDays,
                now: ctx.date
            )
            // Tooltip mirrors the VoiceOver phrasing — verdict in compact
            // form on screen, full sentence on hover. Pointer users get
            // the same «30 min to spare» / «over by 1h» context the
            // assistive-tech path already had.
            let verbose = Self.accessibilityLabel(
                for: forecast,
                pendingMinutes: pendingMinutes,
                overflowingCount: overflowingCount
            )
            HStack(spacing: DS.Spacing.xxs) {
                // Warning glyph escalates the «over» verdict from a quiet
                // text label to something the eye catches in peripheral
                // vision. Destructive tint pairs with the ring's red sector
                // and the «N urgent» pill — same colour channel = same
                // category of bad news.
                if case .over = forecast {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedDestructiveColor)
                        .accessibilityHidden(true)
                }

                // Two-tier verdict: ETA / over-by reads first (secondary
                // tint), the suffix «· N don't fit» reads quieter (tertiary)
                // so the eye lands on the answer, then descends to the
                // qualifier. Birman: «слои информации — главное крупнее».
                // Concatenated `Text` keeps both halves on the same baseline
                // and lets `numericText()` transitions animate digits in
                // both halves smoothly.
                Text(Self.label(for: forecast))
                    .foregroundStyle(skin.resolvedTextSecondary)
                + Text(Self.suffix(forecast: forecast, overflowingCount: overflowingCount))
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            // `DS.Typography.metric` — the verdict carries the
            // numeric facts of the day («Done by 17:30», «4 h 32 min
            // over», «3 h 12 min queued»). Single voice for inline
            // numerics across the backlog header so the prose («Done
            // by») and the digits («17:30») share one rhythm.
            .font(DS.Typography.metric(skin: skin))
            .contentTransition(.numericText())
            .help(verbose)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(verbose)
        }
    }

    /// Visible verdict — kept short so it sits next to the ring without
    /// crowding the header. The ETA case uses an en-dash-free «Done by HH:MM»
    /// (no «—» dash to fight monospaced digits); the overflow case prefixes
    /// the magnitude so a glance sees how much you're over.
    static func label(for forecast: BacklogLogic.CapacityForecast) -> String {
        switch forecast {
        case .fits(let eta, _):
            let timeStr = eta.formatted(date: .omitted, time: .shortened)
            return "Done by \(timeStr)"
        case .over(let byMinutes):
            return "\(DS.formatMinutes(byMinutes)) over capacity"
        case .afterHours(let queuedMinutes):
            return "After hours · \(DS.formatMinutes(queuedMinutes)) queued"
        }
    }

    /// Suffix that names the overflow count in plain English. Returns the
    /// empty string when nothing overflows so the verdict collapses to its
    /// short form. Plural-aware. Birman: «не заставляй считать в уме» —
    /// the reader sees the count directly instead of subtracting fits from
    /// total.
    static func suffix(forecast: BacklogLogic.CapacityForecast, overflowingCount: Int) -> String {
        guard overflowingCount > 0 else { return "" }
        switch forecast {
        case .over, .afterHours:
            return overflowingCount == 1
                ? "\u{00A0}·\u{00A0}1\u{00A0}task doesn't\u{00A0}fit"
                : "\u{00A0}·\u{00A0}\(overflowingCount)\u{00A0}don't\u{00A0}fit"
        case .fits:
            // ETA + leftover overflow shouldn't happen in practice (`.fits`
            // means everything fits), but if a partition rounds differently
            // than the forecast, we'd rather show the discrepancy than
            // silently lie. Fall back to the same plural-aware form.
            return overflowingCount == 1
                ? "\u{00A0}·\u{00A0}1\u{00A0}task doesn't\u{00A0}fit"
                : "\u{00A0}·\u{00A0}\(overflowingCount)\u{00A0}don't\u{00A0}fit"
        }
    }

    /// Verbose accessibility phrasing — VoiceOver reads the full sentence
    /// (with the spare-minutes hint) instead of the compact visual form.
    static func accessibilityLabel(
        for forecast: BacklogLogic.CapacityForecast,
        pendingMinutes: Int,
        overflowingCount: Int = 0
    ) -> String {
        let countSuffix: String
        if overflowingCount > 0 {
            countSuffix = overflowingCount == 1
                ? ". 1 task doesn't fit today."
                : ". \(overflowingCount) tasks don't fit today."
        } else {
            countSuffix = ""
        }
        switch forecast {
        case .fits(let eta, let spareMinutes):
            let timeStr = eta.formatted(date: .omitted, time: .shortened)
            if spareMinutes > 0 {
                return "Backlog finishes at \(timeStr), \(DS.formatMinutes(spareMinutes)) to spare\(countSuffix)"
            }
            return "Backlog finishes at \(timeStr)\(countSuffix)"
        case .over(let byMinutes):
            return "Backlog over capacity by \(DS.formatMinutes(byMinutes))\(countSuffix)"
        case .afterHours(let queuedMinutes):
            return "Workday ended, \(DS.formatMinutes(queuedMinutes)) queued for later\(countSuffix)"
        }
    }
}
