import SwiftUI

struct TimerScreenView: View {
    @Environment(\.activeSkin) private var skin
    let event: CalendarEvent
    var onBack: () -> Void
    var isPinned: Bool = false

    var wallpaper: WallpaperDefinition = WallpaperCatalog.none
    var customPhotoPath: String = ""
    var customPhotoOpacity: Double = 0.25
    var customPhotoBlur: Double = 2
    var skinImageOverride: SkinImageOverride? = nil

    @State private var pulseRing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

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
        isInProgress(now) ? secondsUntilEnd(now) : secondsUntilStart(now)
    }

    private func ringProgress(_ now: Date) -> Double {
        if hasEnded(now) { return 1.0 }
        if isInProgress(now) {
            guard totalDuration > 0 else { return 0 }
            let elapsed = totalDuration - Double(secondsUntilEnd(now))
            return min(elapsed / totalDuration, 1.0)
        }
        let cap = 86400.0
        let clamped = min(Double(secondsUntilStart(now)), cap)
        return clamped / cap
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
                        customPhotoBlur: customPhotoBlur,
                        skinImageOverride: skinImageOverride
                    )
                }

                timerContent(now: now)
            }
            .frame(width: DS.Popover.width, height: DS.Popover.timerHeight)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                pulseRing = true
            }
        }
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
                onBack: {
                    onBack()
                },
                trailing: AnyView(
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
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(.system(size: DS.Size.iconMedium, weight: .medium))
                            .foregroundStyle(isPinned ? DS.Colors.accent : skin.resolvedTextSecondary)
                            .rotationEffect(.degrees(isPinned ? 0 : 45))
                    }
                    .buttonStyle(.borderless)
                    .help(isPinned ? "Unpin window" : "Pin on top")
                    .accessibilityLabel(isPinned ? "Unpin timer window" : "Pin timer window on top")
                )
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
                                .font(.system(.caption, design: .rounded, weight: .medium))
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

                    // Event info card
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        Text(event.title)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.lg)
                    .skinPlatter(skin)
                    .skinPlatterDepth(skin)
                    .staggeredEntrance(index: 1)
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
                        .font(.system(size: size * 0.45, weight: .medium, design: .rounded))
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func statusLabel(_ now: Date) -> String {
        if hasEnded(now) { return "Ended" }
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
