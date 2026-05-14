import SwiftUI
import BuboDomain

// MARK: - Optimizer Insights View
//
// Main-Job fix #2: the visible track record. `IntentLearner` quietly
// gathers acceptance / rejection / temporal-pattern signals, but until
// today none of it was rendered for the user. Trust grows from visible
// history; this view is that visible history.
//
// Lives in Settings > Optimizer below the Delegation Contract. Pure
// derived view — reads `IntentLearner.history`, `intentFrequency`,
// `temporalPatterns` and turns them into plain-language statements.
//
// Birman: "the machine writes its autobiography on the screen so the
// user can audit it."

struct OptimizerInsightsView: View {
    @Environment(OptimizerService.self) private var optimizerService
    @Environment(\.activeSkin) private var skin

    private var learner: IntentLearner { optimizerService.intentLearner }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            header
            metricsRow
            if !accepted.isEmpty || !rejected.isEmpty {
                patternsSection
            } else {
                emptyState
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(skin.accentColor)
                Text("What I've learned about you")
                    .font(DS.Typography.headline(skin: skin))
                    .foregroundStyle(skin.resolvedTextPrimary)
            }
            Text("Every plan you accept teaches me your patterns. Every plan you reject teaches me what to avoid. Here's what I've noticed.")
                .font(.footnote)
                .foregroundStyle(skin.resolvedTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Metrics row

    /// Three quick stats in a row. Each tile is the same shape so the
    /// row reads as a single object instead of three different cards.
    private var metricsRow: some View {
        HStack(spacing: DS.Spacing.md) {
            metricTile(
                title: "Plans run",
                value: "\(learner.history.count)",
                detail: detailForPlansRun
            )
            metricTile(
                title: "Acceptance",
                value: acceptanceRate,
                detail: "How often you keep my suggestions"
            )
            metricTile(
                title: "Patterns",
                value: "\(learner.temporalPatterns.count)",
                detail: "Time-of-day rules I've noticed"
            )
        }
    }

    private func metricTile(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(skin.resolvedTextPrimary)
                .contentTransition(.numericText())
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(skin.resolvedTextSecondary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(skin.resolvedTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                .fill(skin.resolvedTextPrimary.opacity(DS.Mix.surfaceChip))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                .strokeBorder(skin.resolvedTextPrimary.opacity(DS.Mix.surfaceDivider), lineWidth: DS.Border.thin)
        )
    }

    // MARK: - Patterns section

    /// Top temporal patterns rendered as plain-language statements.
    /// `IntentLearner.temporalPatterns` is sorted by `occurrences`, so
    /// the loudest signals come first.
    private var patternsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Patterns I've noticed")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(skin.resolvedTextPrimary)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
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
            .background(
                RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                    .fill(skin.resolvedTextPrimary.opacity(DS.Mix.surfaceChip))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                    .strokeBorder(skin.resolvedTextPrimary.opacity(DS.Mix.surfaceDivider), lineWidth: DS.Border.thin)
            )
        }
    }

    private func patternRow(_ pattern: PatternRow) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(skin.accentColor.opacity(DS.Mix.accentStrong))
                .padding(.top, 7)
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
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: "tray")
                .font(.system(size: 20))
                .foregroundStyle(skin.resolvedTextTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("We're just getting started")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextPrimary)
                Text("Run a few plans and I'll show you what I've noticed about how you like your day organised.")
                    .font(.footnote)
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.radiusMd, style: .continuous)
                .fill(skin.resolvedTextPrimary.opacity(DS.Mix.surfaceChip))
        )
    }

    // MARK: - Derived data

    /// Snapshot of acceptance vs rejection counts. Recomputed on render
    /// — `IntentLearner.history` is small (capped at 200) so this is
    /// cheap.
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

    /// Pre-formatted row for the patterns list. Pulls one canonical
    /// "your top hour" + one "your favourite intent" so the section
    /// stays scannable even when the learner has dozens of micro-
    /// patterns.
    struct PatternRow: Identifiable {
        let id: String
        let headline: String
        let confidence: String
    }

    private var topPatterns: [PatternRow] {
        var rows: [PatternRow] = []

        // 1) Most common hour for acceptance.
        if let busiestHour = busiestAcceptedHour {
            rows.append(PatternRow(
                id: "hour-\(busiestHour.hour)",
                headline: "You usually accept plans around \(formatHour(busiestHour.hour)).",
                confidence: "\(busiestHour.count) of \(accepted.count) accepted plans"
            ))
        }

        // 2) Top frequent intent.
        if let top = learner.intentFrequency.max(by: { $0.value < $1.value }) {
            rows.append(PatternRow(
                id: "intent-\(top.key)",
                headline: "Your favourite intent: \(humanise(intentKey: top.key)).",
                confidence: "Used \(top.value) times"
            ))
        }

        // 3) Day-of-week tilt — which weekday you accept the most plans.
        if let busiestDay = busiestDayOfWeek {
            rows.append(PatternRow(
                id: "dow-\(busiestDay.weekday)",
                headline: "\(weekdayName(busiestDay.weekday)) is your busiest planning day.",
                confidence: "\(busiestDay.count) plans accepted on \(weekdayName(busiestDay.weekday))s"
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
        // `weekdaySymbols` is 0-indexed Sunday-first; `Calendar.weekday`
        // is 1-indexed Sunday-first. Subtract 1 to align.
        let idx = max(0, min(6, weekday - 1))
        return f.weekdaySymbols[idx]
    }

    /// Friendly label for an intent key like `peakEnergy(_:)` →
    /// "Peak energy". Best-effort — the learner stores compact keys,
    /// so we strip parens / camelCase split.
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
