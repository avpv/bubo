import SwiftUI
import BuboDomain

// MARK: - Optimizer Insights View
//
// Apple-philosophy composition: stat-group + grouped surface pattern.
// The previous version rendered three metric tiles AND the patterns
// section AND the empty state as separately-bordered cards (fill +
// stroke on each). Three cards × two surfaces each = six borders
// fighting for attention.
//
// Now: one rounded surface, three vertical columns inside it separated
// by internal hairline dividers — the Apple Health / Fitness stat-group
// idiom. Patterns and empty state share the same single-surface chrome.
// One object on the screen, not six.
//
// Birman: "the machine writes its autobiography on the screen so the
// user can audit it." — but in *one* voice, not three.

struct OptimizerInsightsView: View {
    @Environment(OptimizerService.self) private var optimizerService
    @Environment(\.activeSkin) private var skin

    private var learner: IntentLearner { optimizerService.intentLearner }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            header
            statGroup
            if !accepted.isEmpty || !rejected.isEmpty {
                patternsSection
            } else {
                emptyState
            }
        }
    }

    // MARK: - Header

    /// Eyebrow + title + description block. Apple uses this exact stack
    /// in Settings sub-section openers — small SF symbol next to the
    /// title (never huge), description in quiet body voice underneath.
    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Label("What I've learned about you", systemImage: "sparkles")
                .font(DS.Typography.headline(skin: skin))
                .foregroundStyle(skin.resolvedTextPrimary)
            Text("Every plan you accept teaches me your patterns. Every plan you reject teaches me what to avoid. Here's what I've noticed.")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Stat group
    //
    // One rounded surface, three vertical columns separated by hairline
    // internal dividers — exactly how Apple Fitness, Health and Music
    // present a row of summary metrics. No per-tile fill or stroke.

    private var statGroup: some View {
        HStack(alignment: .top, spacing: 0) {
            statColumn(
                title: "Plans run",
                value: "\(learner.history.count)",
                detail: detailForPlansRun
            )
            statDivider
            statColumn(
                title: "Acceptance",
                value: acceptanceRate,
                detail: "How often you keep my suggestions"
            )
            statDivider
            statColumn(
                title: "Patterns",
                value: "\(learner.temporalPatterns.count)",
                detail: "Time-of-day rules I've noticed"
            )
        }
        .padding(.vertical, DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GroupedSurfaceBackground(skin: skin))
    }

    private func statColumn(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(skin.resolvedTextPrimary)
                .contentTransition(.numericText())
            Text(title)
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(skin.resolvedTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Internal hairline between stat columns. Apple's stat-group uses
    /// a quarter-height vertical line inset from top and bottom so the
    /// divider doesn't compete with the rounded surface edge.
    private var statDivider: some View {
        Rectangle()
            // Skin-resolved — the raw system separator ignored the
            // active skin while every neighbouring line tracks it.
            .fill(skin.resolvedTextPrimary.opacity(DS.Mix.surfaceDivider))
            .frame(width: 0.5)
            .padding(.vertical, DS.Spacing.xs)
    }

    // MARK: - Patterns section

    private var patternsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Patterns I've noticed")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(skin.resolvedTextPrimary)

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                ForEach(topPatterns, id: \.id) { pattern in
                    patternRow(pattern)
                }
                if topPatterns.isEmpty {
                    Text("I'm still gathering enough data to spot patterns. Run a few plans and I'll start surfacing rules here.")
                        .font(.footnote)
                        .foregroundStyle(skin.resolvedTextTertiary)
                }
            }
            .padding(DS.Spacing.md)
            .modifier(GroupedSurfaceBackground(skin: skin))
        }
    }

    /// Native `Label` row. Apple's pattern in Settings / Notes /
    /// Reminders for descriptive list rows: SF Symbol in leading slot,
    /// title and quiet subline stacked on the right. No hand-tuned 4pt
    /// `circle.fill` micro-bullets — Apple uses a real glyph or no
    /// glyph at all, never sub-text decoration.
    private func patternRow(_ pattern: PatternRow) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(pattern.headline)
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(pattern.confidence)
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: pattern.symbol)
                .font(.footnote)
                .foregroundStyle(skin.accentColor)
                .frame(width: 18, alignment: .leading)
        }
    }

    // MARK: - Empty state

    /// Native `ContentUnavailableView` — Apple's macOS 14+ idiom for
    /// "nothing to show yet". Symbol + title + description + optional
    /// action; we don't need an action here so the view is the symbol
    /// and prose only.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("We're just getting started", systemImage: "tray")
        } description: {
            Text("Run a few plans and I'll show you what I've noticed about how you like your day organised.")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.md)
        .modifier(GroupedSurfaceBackground(skin: skin))
    }

    // MARK: - Derived data

    private var accepted: [IntentLearner.IntentExecution] {
        learner.history.filter { $0.outcome == .accepted }
    }
    private var rejected: [IntentLearner.IntentExecution] {
        learner.history.filter { $0.outcome == .rejected }
    }

    private var acceptanceRate: String {
        let total = learner.history.count
        guard total > 0 else { return "—" }
        let pct = Int((Double(accepted.count) / Double(total)) * 100.0)
        return "\(pct)%"
    }

    private var detailForPlansRun: String {
        let count = learner.history.count
        if count == 0 { return "Run Plan once and I'll start counting" }
        if count == 1 { return "1 plan so far" }
        return "Across the last \(count) plans"
    }

    /// Pre-formatted row for the patterns list. Carries an SF Symbol
    /// per row so the `Label` composition has a real glyph rather than
    /// a generic bullet.
    struct PatternRow: Identifiable {
        let id: String
        let headline: String
        let confidence: String
        let symbol: String
    }

    private var topPatterns: [PatternRow] {
        var rows: [PatternRow] = []

        if let busiestHour = busiestAcceptedHour {
            rows.append(PatternRow(
                id: "hour-\(busiestHour.hour)",
                headline: "You usually accept plans around \(formatHour(busiestHour.hour)).",
                confidence: "\(busiestHour.count) of \(accepted.count) accepted plans",
                symbol: "clock"
            ))
        }

        if let top = learner.intentFrequency.max(by: { $0.value < $1.value }) {
            rows.append(PatternRow(
                id: "intent-\(top.key)",
                headline: "Your favourite intent: \(humanise(intentKey: top.key)).",
                confidence: "Used \(top.value) times",
                symbol: "star"
            ))
        }

        if let busiestDay = busiestDayOfWeek {
            rows.append(PatternRow(
                id: "dow-\(busiestDay.weekday)",
                headline: "\(weekdayName(busiestDay.weekday)) is your busiest planning day.",
                confidence: "\(busiestDay.count) plans accepted on \(weekdayName(busiestDay.weekday))s",
                symbol: "calendar"
            ))
        }

        return rows
    }

    private var busiestAcceptedHour: (hour: Int, count: Int)? {
        let buckets = Dictionary(grouping: accepted, by: { $0.hour })
            .mapValues(\.count)
        guard let best = buckets.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, best.value)
    }

    private var busiestDayOfWeek: (weekday: Int, count: Int)? {
        let buckets = Dictionary(grouping: accepted, by: { $0.dayOfWeek })
            .mapValues(\.count)
        guard let best = buckets.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, best.value)
    }

    // MARK: - Formatters

    private func formatHour(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func weekdayName(_ weekday: Int) -> String {
        let f = DateFormatter()
        let idx = max(0, min(6, weekday - 1))
        return f.weekdaySymbols[idx]
    }

    private func humanise(intentKey: String) -> String {
        let bare = intentKey.split(separator: "(").first.map(String.init) ?? intentKey
        var out = ""
        for ch in bare {
            if ch.isUppercase, !out.isEmpty {
                out.append(" ")
            }
            out.append(ch)
        }
        return out.capitalized
    }
}

// MARK: - Grouped surface

/// Apple-philosophy grouped surface: ONE fill, no stroke. The rounded
/// rectangle has a single low-alpha fill that reads as a surface lift
/// against the popover backdrop. Replaces the previous fill+stroke
/// double-surface pattern that put two borders around every card.
///
/// Centralised so all three sections of `OptimizerInsightsView` (stats,
/// patterns, empty state) share the same chrome and re-skins keep them
/// in lockstep.
private struct GroupedSurfaceBackground: ViewModifier {
    let skin: SkinDefinition

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                    .fill(skin.resolvedTextPrimary.opacity(DS.Mix.surfaceChip))
            )
    }
}
