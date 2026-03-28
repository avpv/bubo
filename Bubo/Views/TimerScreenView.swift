import SwiftUI

struct TimerScreenView: View {
    let event: CalendarEvent
    var onBack: () -> Void
    var isPinned: Bool = false

    @State private var now = Date()
    @State private var pulseRing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var secondsUntilStart: Int {
        max(Int(event.startDate.timeIntervalSince(now)), 0)
    }

    private var secondsUntilEnd: Int {
        max(Int(event.endDate.timeIntervalSince(now)), 0)
    }

    private var totalDuration: TimeInterval {
        event.endDate.timeIntervalSince(event.startDate)
    }

    private var isInProgress: Bool {
        secondsUntilStart <= 0 && secondsUntilEnd > 0
    }

    private var hasEnded: Bool {
        secondsUntilStart <= 0 && secondsUntilEnd <= 0
    }

    private var activeSeconds: Int {
        isInProgress ? secondsUntilEnd : secondsUntilStart
    }

    /// Ring progress: drains from 1→0 before start, fills 0→1 during event.
    private var ringProgress: Double {
        if hasEnded { return 1.0 }
        if isInProgress {
            guard totalDuration > 0 else { return 0 }
            let elapsed = totalDuration - Double(secondsUntilEnd)
            return min(elapsed / totalDuration, 1.0)
        }
        // "Starts in" — show remaining fraction (drains toward zero)
        // Cap at 24h so multi-day events still show a meaningful arc
        let cap = 86400.0
        let clamped = min(Double(secondsUntilStart), cap)
        return clamped / cap
    }

    private var accentColor: Color {
        if hasEnded { return DS.Colors.textTertiary }
        if isInProgress { return DS.Colors.accent }
        return DS.urgencyColor(minutesUntil: secondsUntilStart / 60)
    }

    var body: some View {
        VStack(spacing: 0) {
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
                            NotificationCenter.default.post(
                                name: .pinTimerWindow,
                                object: nil,
                                userInfo: ["event": event]
                            )
                        }
                    } label: {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(.system(size: DS.Size.iconMedium, weight: .medium))
                            .foregroundStyle(isPinned ? DS.Colors.accent : DS.Colors.textSecondary)
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
                        // Track
                        Circle()
                            .stroke(accentColor.opacity(0.12), lineWidth: 4)
                            .frame(width: 180, height: 180)

                        // Progress arc
                        if !hasEnded {
                            Circle()
                                .trim(from: 0, to: ringProgress)
                                .stroke(
                                    accentColor,
                                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                                )
                                .frame(width: 180, height: 180)
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 1), value: ringProgress)
                        }

                        // Subtle glow
                        Circle()
                            .fill(accentColor.opacity(pulseRing ? 0.06 : 0.02))
                            .frame(width: 170, height: 170)
                            .blur(radius: 20)

                        // Center content
                        VStack(spacing: DS.Spacing.sm) {
                            Text(statusLabel)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(DS.Colors.textTertiary)
                                .textCase(.uppercase)
                                .tracking(1.5)

                            if hasEnded {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 36, weight: .light))
                                    .foregroundStyle(DS.Colors.textTertiary)
                            } else if hasDays {
                                // Two-line layout for days
                                VStack(spacing: DS.Spacing.xxs) {
                                    timerRow(Array(timeComponents.prefix(2)), size: 28)
                                    timerRow(Array(timeComponents.suffix(2)), size: 28)
                                }
                            } else {
                                timerRow(timeComponents, size: 32)
                            }
                        }
                    }
                    .staggeredEntrance(index: 0)

                    // Event info card
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        Text(event.title)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .lineLimit(2)

                        HStack(spacing: DS.Spacing.md) {
                            Label(event.formattedDate, systemImage: "calendar")
                                .font(.caption)
                                .foregroundStyle(DS.Colors.textSecondary)

                            Label(event.formattedTimeRange, systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(DS.Colors.textSecondary)
                        }

                        if let location = event.location, !location.isEmpty {
                            Label(location, systemImage: "location.fill")
                                .font(.caption)
                                .foregroundStyle(DS.Colors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.lg)
                    .background(DS.Materials.platter)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
                    .shadow(color: DS.Shadows.ambientColor, radius: DS.Shadows.ambientRadius, y: DS.Shadows.ambientY)
                    .staggeredEntrance(index: 1)
                }
                .padding(.horizontal, DS.Spacing.xl)
                .padding(.top, DS.Spacing.lg)
                .padding(.bottom, DS.Spacing.xl)
            }
        }
        .frame(width: DS.Popover.width, height: isPinned ? DS.Popover.timerHeight : DS.Popover.height)
        .onReceive(timer) { _ in
            withAnimation(.linear(duration: 0.3)) {
                now = Date()
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                pulseRing = true
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
                        .foregroundStyle(DS.Colors.textPrimary)
                        .contentTransition(.numericText())
                    Text(comp.unit)
                        .font(.system(size: size * 0.45, weight: .medium, design: .rounded))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
            }
        }
    }

    // MARK: - Helpers

    private var statusLabel: String {
        if hasEnded { return "Ended" }
        if isInProgress { return "Ends in" }
        return "Starts in"
    }

    private var hasDays: Bool {
        activeSeconds >= 86400
    }

    private struct TimeComponent: Identifiable {
        let id: String
        let value: String
        let unit: String
    }

    private var timeComponents: [TimeComponent] {
        let total = activeSeconds
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
