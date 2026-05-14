import SwiftUI
import BuboDomain
import BuboOptimizer

// MARK: - Optimizer Rules Strip
//
// Main-Job fix #6: every rule the optimizer enforces, surfaced as a
// scrollable chip row directly under the popover header. Today these
// rules live in five separate places (Settings, row hover, working-
// hours bookend, intent learner, command palette) — the user has to
// hunt for them. The strip puts them on one line so "the machine that
// knows my rules" becomes literal: I can see what it knows, in one
// glance, all the time.
//
// Each chip carries one rule:
//   • working hours window (`🕘 9–18`)
//   • working days (`📍 Mon–Fri`)
//   • peak energy hours (`⚡ 10–12`)
//   • locked events count (`🔒 3 locked`)
//   • excluded events count (`🙈 1 hidden`)
//   • capacity forecast (`🟢 fits` / `🟠 tight` / `🔴 over`)
//
// Tap on a chip surfaces an inline editor. For chips that don't have
// inline editing yet, tap routes to Settings > Optimizer with the
// relevant section anchored.
//
// Birman: «rules are objects on the screen, not invisible defaults».

struct OptimizerRulesStrip: View {
    /// The window of working hours (inclusive lower / upper bound).
    let workingHours: ClosedRange<Int>
    /// Weekday set, 1-indexed Sunday-first (matches `Calendar.weekday`).
    let workingDays: Set<Int>
    /// Hour set of peak-energy windows from `OptimizerPreferences`.
    let peakEnergyHours: Set<Int>
    /// Number of locked events (`OptimizerService.lockedEventIds.count`).
    let lockedCount: Int
    /// Number of excluded events.
    let excludedCount: Int
    /// Capacity forecast — drives the colour of the capacity chip.
    let capacityForecast: BacklogLogic.CapacityForecast
    /// Tap handler routing the user to the appropriate Settings pane.
    /// Hosts pass `{ NotificationCenter.default.post(... navigateToPane ...) }`
    /// or a deep-link closure. Each rule chip calls this with its own
    /// `RuleAnchor` so the destination opens with the right section
    /// highlighted.
    var onEdit: ((RuleAnchor) -> Void)? = nil

    @Environment(\.activeSkin) private var skin

    enum RuleAnchor: String {
        case workingHours
        case workingDays
        case peakEnergy
        case locked
        case excluded
        case capacity
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                ruleChip(
                    glyph: "🕘",
                    label: workingHoursLabel,
                    tone: .quiet,
                    anchor: .workingHours
                )
                if !workingDays.isEmpty, workingDays.count < 7 {
                    ruleChip(
                        glyph: "📍",
                        label: workingDaysLabel,
                        tone: .quiet,
                        anchor: .workingDays
                    )
                }
                if !peakEnergyHours.isEmpty {
                    ruleChip(
                        glyph: "⚡",
                        label: peakEnergyLabel,
                        tone: .accent,
                        anchor: .peakEnergy
                    )
                }
                if lockedCount > 0 {
                    ruleChip(
                        glyph: nil,
                        systemImage: "lock.fill",
                        label: "\(lockedCount) locked",
                        tone: .accent,
                        anchor: .locked
                    )
                }
                if excludedCount > 0 {
                    ruleChip(
                        glyph: nil,
                        systemImage: "eye.slash.fill",
                        label: "\(excludedCount) hidden",
                        tone: .warning,
                        anchor: .excluded
                    )
                }
                capacityChip
            }
            .padding(.horizontal, DS.Spacing.contentMargin)
            .padding(.vertical, DS.Spacing.xs)
        }
        .accessibilityLabel("Optimizer rules")
    }

    // MARK: - Chip factory

    @ViewBuilder
    private func ruleChip(
        glyph: String? = nil,
        systemImage: String? = nil,
        label: String,
        tone: BannerTone,
        anchor: RuleAnchor
    ) -> some View {
        let tint = tone.color(skin: skin)
        Button {
            Haptics.tap()
            onEdit?(anchor)
        } label: {
            HStack(spacing: 4) {
                if let glyph {
                    Text(glyph)
                        .font(.system(size: 10.5))
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: skin.resolvedFontDesign))
                    .foregroundStyle(tone == .quiet ? skin.resolvedTextSecondary : tint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill((tone == .quiet ? skin.resolvedTextPrimary : tint).opacity(tone == .quiet ? DS.Mix.surfaceChip : DS.Mix.accentLight))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        (tone == .quiet ? skin.resolvedTextPrimary : tint).opacity(tone == .quiet ? DS.Mix.surfaceDivider : DS.Mix.accentStrong),
                        lineWidth: DS.Border.thin
                    )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(helpText(for: anchor))
    }

    @ViewBuilder
    private var capacityChip: some View {
        let (tone, label, accessibility) = capacityPresentation
        ruleChip(
            glyph: nil,
            systemImage: tone == .destructive ? "exclamationmark.circle.fill" : (tone == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"),
            label: label,
            tone: tone,
            anchor: .capacity
        )
        .accessibilityLabel(accessibility)
    }

    // MARK: - Derived labels

    private var workingHoursLabel: String {
        let start = workingHours.lowerBound
        let end = workingHours.upperBound
        return "\(start)\u{2013}\(end)"
    }

    private var workingDaysLabel: String {
        // Compact form: Mon–Fri when contiguous, else "Mon Wed Fri".
        let weekdaySymbols: [Int: String] = [
            1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed",
            5: "Thu", 6: "Fri", 7: "Sat"
        ]
        let sorted = workingDays.sorted()
        guard sorted.count > 1 else {
            return sorted.first.flatMap { weekdaySymbols[$0] } ?? "—"
        }
        let isContiguous = zip(sorted, sorted.dropFirst()).allSatisfy { $1 - $0 == 1 }
        if isContiguous, let first = sorted.first, let last = sorted.last,
           let firstName = weekdaySymbols[first], let lastName = weekdaySymbols[last] {
            return "\(firstName)\u{2013}\(lastName)"
        }
        return sorted.compactMap { weekdaySymbols[$0] }.joined(separator: " ")
    }

    private var peakEnergyLabel: String {
        let sorted = peakEnergyHours.sorted()
        guard let first = sorted.first else { return "—" }
        if sorted.count == 1 {
            return "\(first):00"
        }
        let last = sorted.last ?? first
        let isContiguous = zip(sorted, sorted.dropFirst()).allSatisfy { $1 - $0 == 1 }
        if isContiguous {
            return "\(first)\u{2013}\(last)"
        }
        return sorted.map(String.init).joined(separator: ",")
    }

    private var capacityPresentation: (tone: BannerTone, label: String, accessibility: String) {
        switch capacityForecast {
        case .fits:
            return (.success, "fits today", "Capacity: fits today")
        case .over:
            return (.warning, "tight", "Capacity: tight — close to over")
        case .afterHours:
            return (.destructive, "over", "Capacity: over — overflow into after-hours")
        }
    }

    private func helpText(for anchor: RuleAnchor) -> String {
        switch anchor {
        case .workingHours: return "Working hours window — tap to adjust"
        case .workingDays: return "Working days — tap to adjust"
        case .peakEnergy: return "Peak energy hours — tap to adjust"
        case .locked: return "Locked events the optimizer won't move — tap to manage"
        case .excluded: return "Events the optimizer ignores — tap to manage"
        case .capacity: return "Today's capacity forecast — tap for details"
        }
    }
}
