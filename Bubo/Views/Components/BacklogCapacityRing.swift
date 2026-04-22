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
    @State private var isPopoverPresented = false
    @State private var isHovered = false

    /// Ratio of workload to available time. Guards against division-by-zero
    /// when the workday is over (remaining = 0): in that case, any workload
    /// is overflow; an empty backlog still reads as "fine" (returns 0).
    private var fraction: Double {
        BacklogLogic.capacityFraction(
            pendingMinutes: pendingMinutes,
            remainingWorkdayMinutes: remainingWorkdayMinutes
        )
    }

    private var color: Color {
        switch fraction {
        case ..<0.8: return .green
        case ..<1.0: return skin.accentColor
        case ..<1.2: return .orange
        default:     return skin.resolvedDestructiveColor
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
                    .trim(from: 0, to: min(max(fraction, 0.05), 1.0))
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextSecondary)

                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                    Text("Hours")
                        .font(.caption)
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
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextSecondary)
                    WorkingDaysPicker(selection: $service.workingDays)
                }

                Text("Applies to all planning — also in Settings › Optimizer.")
                    .font(.caption2)
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
                .font(.caption)
                .foregroundStyle(skin.resolvedTextSecondary)
            Spacer(minLength: DS.Spacing.sm)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(skin.resolvedTextPrimary)
        }
    }
}
