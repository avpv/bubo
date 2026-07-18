import SwiftUI

/// The popover's scrolling timeline: an interleaved list of events,
/// free slots, ghost previews, and inline NOW markers, grouped by day
/// with sticky day-section headers. Wraps the LazyVStack chrome,
/// scroll-position binding, parallax read-out, and the «Load more
/// days» footer; delegates the per-day rendering back to the host via
/// `dayHeader` / `daySection` closures so callbacks, services, and
/// state stay rooted on `MenuBarView`. The optional `leadingContent`
/// closure carries the wellness + roll-forward banners that share the
/// same scrolling content as the timeline.
///
/// Owns no state of its own — `scrollPositionID` and `listScrollY`
/// flow through as `@Binding`s so the host's day-nav cluster and
/// background parallax keep their single source of truth.
struct EventList<LeadingContent: View, DayHeader: View, DaySection: View>: View {
    @Binding var scrollPositionID: String?
    @Binding var listScrollY: CGFloat
    let days: [MenuBarTimelineDay]
    let extraDaysShown: Int
    let extraDaysCap: Int
    let onLoadMoreDays: () -> Void
    /// Echoed straight into the LazyVStack's `.animation(_:value:)`
    /// modifier — drives the disintegration animation on event removals.
    let disintegratingEventIDs: Set<String>
    /// Fired when the day section owning the viewport top changes.
    /// The pinned (sticky) headers make «which day is the user
    /// reading» a measurable fact; the host mirrors it into its
    /// day-nav focus so the header cluster follows manual scrolling,
    /// not just its own buttons. (`scrollPosition(id:)` can't do this
    /// job: its `String?` binding never matches the `Date`-identified
    /// day sections.)
    let onVisibleDayChange: (Date) -> Void
    let leadingContent: () -> LeadingContent
    let dayHeader: (MenuBarTimelineDay) -> DayHeader
    let daySection: (MenuBarTimelineDay) -> DaySection

    init(
        scrollPositionID: Binding<String?>,
        listScrollY: Binding<CGFloat>,
        days: [MenuBarTimelineDay],
        extraDaysShown: Int,
        extraDaysCap: Int,
        onLoadMoreDays: @escaping () -> Void,
        disintegratingEventIDs: Set<String>,
        onVisibleDayChange: @escaping (Date) -> Void = { _ in },
        @ViewBuilder leadingContent: @escaping () -> LeadingContent,
        @ViewBuilder dayHeader: @escaping (MenuBarTimelineDay) -> DayHeader,
        @ViewBuilder daySection: @escaping (MenuBarTimelineDay) -> DaySection
    ) {
        self._scrollPositionID = scrollPositionID
        self._listScrollY = listScrollY
        self.days = days
        self.extraDaysShown = extraDaysShown
        self.extraDaysCap = extraDaysCap
        self.onLoadMoreDays = onLoadMoreDays
        self.disintegratingEventIDs = disintegratingEventIDs
        self.onVisibleDayChange = onVisibleDayChange
        self.leadingContent = leadingContent
        self.dayHeader = dayHeader
        self.daySection = daySection
    }

    var body: some View {
        ScrollView {
            // Timeline is not a platter card (see mainContent), so this
            // LazyVStack owns its own horizontal margin via
            // `contentMargin` — putting event rows, day headers, and
            // smart banners on the same 16pt vertical axis as the
            // QuickActions card, the Backlog card, the header, and the
            // footer. Gestalt: outer space (between day groups) > inner
            // space (row to row inside a day) — handled by the `lg`
            // sibling spacing between sections plus the bar background
            // on the sticky day-section header (the previous explicit
            // `SkinSeparator` between groups is gone — the header's
            // tinted material now does the divider's work).
            // Density pass: 16pt → 12pt between day groups. Gestalt
            // (outer > inner) still holds because day rows themselves run
            // at 4pt vertical padding, so 12pt outer reads as a clear day
            // boundary without burning a third of every popover height on
            // gaps. Birman: density is respect for attention.
            LazyVStack(alignment: .leading, spacing: DS.Spacing.md, pinnedViews: [.sectionHeaders]) {
                leadingContent()

                ForEach(days) { day in
                    // `Section` + LazyVStack's `pinnedViews:
                    // [.sectionHeaders]` keeps the day title pinned to
                    // the top of the popover scroll area until the
                    // next day's header pushes it out — mirrors the
                    // prototype's `position: sticky` day-headers and
                    // gives the user a constant «what day am I
                    // reading» landmark when scanning the timeline.
                    // The bar background on dayHeader keeps text
                    // readable while events scroll under it; the
                    // visual it produces also subsumes the previous
                    // explicit SkinSeparator between day groups.
                    Section {
                        // Density pass: wrap the day's interior in its own
                        // VStack so intra-day rows sit on a 4pt rhythm
                        // (prototype `.day-section .events { gap: 4px }`)
                        // while inter-day spacing stays at the LazyVStack's
                        // 12pt, preserving Gestalt outer > inner.
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            daySection(day)
                        }
                    } header: {
                        dayHeader(day)
                            // Report this header's top edge so the
                            // current day is derived from geometry
                            // (see `onVisibleDayChange`).
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: DayHeaderMinYKey.self,
                                        value: [day.date: geo.frame(in: .named("eventListScroll")).minY]
                                    )
                                }
                            )
                    }
                }

                // «Load more days» footer — extends the timeline horizon
                // by one week per tap up to `extraDaysCap`. New days
                // appear below; existing scroll position is preserved
                // by `scrollPosition(id:)` so the user stays anchored
                // to whatever they were reading.
                if extraDaysShown < extraDaysCap {
                    LoadMoreDaysButton {
                        onLoadMoreDays()
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.contentMargin)
            // Density pass: 12pt → 8pt outer vertical padding so the first
            // event row sits closer to the day-section heading and the
            // last row sits closer to the footer. The list interior keeps
            // its own 4pt row gap, the section heading already adds xxs
            // top padding, so 8pt here matches the prototype's tight
            // top/bottom rhythm without crowding the controls.
            .padding(.vertical, DS.Spacing.sm)
            .scrollTargetLayout()
            .id("eventListTop")
            .animation(DS.Animation.smoothSpring, value: disintegratingEventIDs)
            // Read the LazyVStack's position inside the scroll view's
            // coordinate space. As the user scrolls down, `minY` grows
            // negative; we feed that straight into `listScrollY`, then
            // `parallaxOffset` (on the host) applies the dampening + clamp.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named("eventListScroll")).minY
            } action: { newValue in
                listScrollY = newValue
            }
        }
        .coordinateSpace(.named("eventListScroll"))
        .scrollPosition(id: $scrollPositionID)
        .scrollContentBackground(.hidden)
        .onPreferenceChange(DayHeaderMinYKey.self) { headerTops in
            if let current = currentDay(headerTops: headerTops) {
                onVisibleDayChange(current)
            }
        }
    }
}

/// Day-header top edges (minY in the `eventListScroll` space), keyed by
/// day date. Only rendered (lazy-mounted) headers report, which is
/// exactly the set that matters for «what is the user looking at».
private struct DayHeaderMinYKey: PreferenceKey {
    static let defaultValue: [Date: CGFloat] = [:]
    static func reduce(value: inout [Date: CGFloat], nextValue: () -> [Date: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Resolve which day owns the viewport top. The pinned header rides at
/// minY ≈ 0 while its section is current and goes negative once the
/// next header pushes it out, so the DEEPEST header at or above the pin
/// line is the current day. Before any header reaches the pin line
/// (leading content still on screen at the top) the first rendered
/// header wins.
private func currentDay(headerTops: [Date: CGFloat]) -> Date? {
    // Pin line sits a hair below 0 in theory; 12 pt of slack absorbs
    // the LazyVStack's own vertical padding without ever reaching the
    // next header, which unpins the current one before crossing it.
    let pinLine: CGFloat = 12
    if let pinned = headerTops
        .filter({ $0.value <= pinLine })
        .max(by: { $0.value < $1.value }) {
        return pinned.key
    }
    return headerTops.min(by: { $0.value < $1.value })?.key
}
