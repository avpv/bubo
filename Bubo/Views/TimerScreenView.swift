import SwiftUI

struct TimerScreenView: View {
    let event: CalendarEvent
    var onBack: () -> Void

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

    private var progress: Double {
        if hasEnded { return 1.0 }
        if isInProgress {
            guard totalDuration > 0 else { return 0 }
            let elapsed = totalDuration - Double(secondsUntilEnd)
            return min(elapsed / totalDuration, 1.0)
        }
        return 0
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
                showBack: true,
                onBack: onBack
            )

            VStack(spacing: DS.Spacing.xl) {
                Spacer(minLength: DS.Spacing.md)

                // Timer ring
                ZStack {
                    // Track
                    Circle()
                        .stroke(accentColor.opacity(0.12), lineWidth: 5)
                        .frame(width: 180, height: 180)

                    // Progress arc (only when in progress)
                    if isInProgress {
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(
                                accentColor,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round)
                            )
                            .frame(width: 180, height: 180)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: progress)
                    }

                    // Glow
                    Circle()
                        .stroke(accentColor.opacity(pulseRing ? 0.12 : 0.04), lineWidth: 14)
                        .frame(width: 194, height: 194)
                        .blur(radius: 10)

                    // Center content
                    VStack(spacing: DS.Spacing.xs) {
                        Text(statusLabel)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(DS.Colors.textTertiary)
                            .textCase(.uppercase)
                            .tracking(1.5)

                        if hasEnded {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(DS.Colors.textTertiary)
                        } else {
                            // Countdown digits
                            HStack(spacing: 0) {
                                ForEach(timeComponents, id: \.id) { comp in
                                    HStack(spacing: 1) {
                                        Text(comp.value)
                                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                                            .foregroundStyle(DS.Colors.textPrimary)
                                            .contentTransition(.numericText())
                                        Text(comp.unit)
                                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                                            .foregroundStyle(DS.Colors.textTertiary)
                                            .offset(y: 5)
                                    }
                                    .padding(.horizontal, 1)
                                }
                            }
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

                Spacer(minLength: DS.Spacing.md)
            }
            .padding(.horizontal, DS.Spacing.xl)
            .frame(maxHeight: DS.Popover.detailMaxHeight)
        }
        .frame(width: DS.Popover.width)
        .frame(minHeight: DS.Popover.detailMinHeight)
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

    // MARK: - Helpers

    private var statusLabel: String {
        if hasEnded { return "Ended" }
        if isInProgress { return "Ends in" }
        return "Starts in"
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
