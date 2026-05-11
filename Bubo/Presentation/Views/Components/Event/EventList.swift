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
    }
}
