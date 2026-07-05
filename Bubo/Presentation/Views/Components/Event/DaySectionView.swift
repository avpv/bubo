import SwiftUI

/// Section header used inside the MenuBarView timeline.
///
/// Apple-philosophy composition: an **eyebrow + title** stack (small-caps
/// «TODAY» / «TOMORROW» eyebrow above a larger day title) plus a quiet
/// metadata subhead — same vocabulary Apple uses for `Section` headers in
/// Music, Mail, News and the macOS Settings.app. The previous version
/// crammed eyebrow + title + summary into a single horizontal strip;
/// here the eyebrow stacks vertically so the eye reads day-context
/// first, then day-name, then optional summary.
///
/// The sticky strip uses `.regularMaterial` rather than a flat tint —
/// Apple's «depth via translucency» for sticky chrome means the
/// section banner shows the content behind it as it scrolls, not a
/// solid opaque band.
struct DaySectionHeader<Trailing: View>: View {
    let date: Date
    let count: Int
    /// Quiet metadata phrase under the title — e.g. «next in 5 h 18 min»,
    /// «all done», «3 events». Pluralisation and composition is built by
    /// the header itself from `count` + `meta`.
    let meta: String?
    /// Optional trailing toolbar item — typically a Plan-day menu on the
    /// Today row. Other days pass `EmptyView()`.
    let trailing: Trailing

    init(
        date: Date,
        count: Int,
        meta: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.date = date
        self.count = count
        self.meta = meta
        self.trailing = trailing()
    }

    @Environment(\.activeSkin) private var skin

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.md) {
            // Title column: eyebrow above title, summary beneath.
            VStack(alignment: .leading, spacing: 2) {
                eyebrow
                Text(dayTitle)
                    .font(.system(size: 15, weight: .semibold, design: skin.resolvedFontDesign))
                    .foregroundStyle(skin.resolvedTextPrimary)
                if !summaryString.isEmpty {
                    Text(summaryString)
                        .font(.system(size: 11, weight: .regular, design: skin.resolvedFontDesign))
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)

            trailing
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)
                .padding(.leading, DS.Spacing.lg)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityHeading)
        .accessibilityAddTraits(.isHeader)
    }

    /// Eyebrow above the day title — «Today», «Tomorrow», or the
    /// day-of-week abbreviation for further-out dates. Uses the shared
    /// `SectionLabel` voice (mixed-case quiet subhead) so the timeline's
    /// day rubrics, the palette sections, and form section labels all
    /// read as one typographic object; today keeps its accent tint.
    @ViewBuilder
    private var eyebrow: some View {
        SectionLabel(text: eyebrowLabel, tint: isToday ? skinAccent : nil)
    }

    private var eyebrowLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return DS.dayOfWeekFormatter.string(from: date)
    }

    /// Title underneath the eyebrow. For today/tomorrow this is the
    /// calendar date («May 16»); for further-out dates this is the
    /// full date string. Either way the title is *concrete* — what
    /// section the eye is in — and the eyebrow is the *context*.
    private var dayTitle: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) || cal.isDateInTomorrow(date) {
            return DS.daySectionShortFormatter.string(from: date)
        }
        return DS.daySectionFormatter.string(from: date)
    }

    /// Compact «3 events · next in 5 h 18 min» under the title.
    ///
    /// PRINCIPLES §3 (REDESIGN.md R5): today's summary is EMPTY — the
    /// popover header already carries today's count and «now/next»,
    /// and the working-hours boundary rows sit right below in the same
    /// section. Repeating them here produced the visible «No events
    /// today» / «9–22 · 0 events» double. Other days keep count + meta:
    /// the popover header doesn't speak for them.
    private var summaryString: String {
        guard !isToday else { return "" }
        let countCopy = "\(count) \(count == 1 ? "event" : "events")"
        var parts: [String] = [countCopy]
        if let meta {
            parts.append(meta)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var skinAccent: Color {
        skin.isClassic ? DS.Colors.accent : skin.accentColor
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    private var accessibilityHeading: String {
        "\(eyebrowLabel), \(dayTitle), \(summaryString)"
    }
}
