import SwiftUI
import BuboDomain

/// Compact popover header carrying day title, week-strip-as-navigation,
/// a filter menu, and a ⌘K hint that opens the command palette.
/// Replaces the older multi-row header (`BUBO` eyebrow + headline +
/// metric subtitle + `← Today →` cluster + SHOW filter bar) by folding
/// every chrome control into one strip.
struct MenuBarHeaderV2View: View {

    let focusedDate: Date
    let weekDates: [Date]
    let densityFor: (Date) -> Double
    let usedColors: [EventColorTag]
    @Binding var colorFilter: EventColorTag?
    @Binding var freeSlotFilter: FreeSlotFilter

    let onSelectDate: (Date) -> Void
    let onOpenPalette: () -> Void

    @Environment(\.activeSkin) private var skin

    private var anyFilterActive: Bool {
        colorFilter != nil || freeSlotFilter.isActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: DS.Spacing.sm) {
                Text(dateLabel)
                    .font(DS.Typography.headline(skin: skin))
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .layoutPriority(2)

                Spacer(minLength: DS.Spacing.sm)

                filterMenu
                paletteButton
            }

            WeekStripView(
                dates: weekDates,
                focused: focusedDate,
                densityFor: densityFor,
                onSelect: onSelectDate
            )
        }
        .padding(.horizontal, DS.Spacing.contentMargin)
        .padding(.top, DS.Spacing.sm)
        .padding(.bottom, DS.Spacing.xs)
    }

    private var dateLabel: String {
        let fmt = DateFormatter()
        fmt.locale = Locale.current
        if Calendar.current.isDateInToday(focusedDate) {
            fmt.setLocalizedDateFormatFromTemplate("EEEE d MMM")
            return fmt.string(from: focusedDate)
        }
        fmt.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return fmt.string(from: focusedDate)
    }

    @ViewBuilder
    private var filterMenu: some View {
        Menu {
            Section("Show only") {
                ForEach(usedColors, id: \.self) { tag in
                    Button {
                        Haptics.tap()
                        freeSlotFilter = .all
                        colorFilter = (colorFilter == tag) ? nil : tag
                    } label: {
                        Label(
                            tag.contextLabel ?? tag.rawValue.capitalized,
                            systemImage: colorFilter == tag ? "checkmark" : "circle.fill"
                        )
                    }
                }
            }
            Section("Free slots") {
                Button {
                    Haptics.tap()
                    colorFilter = nil
                    freeSlotFilter = .onlyFree
                } label: {
                    Label("Only free time", systemImage: freeSlotFilter == .onlyFree ? "checkmark" : "rectangle.dashed")
                }
                Button {
                    Haptics.tap()
                    colorFilter = nil
                    freeSlotFilter = .hideFree
                } label: {
                    Label("Hide free slots", systemImage: freeSlotFilter == .hideFree ? "checkmark" : "eye.slash")
                }
            }
            if anyFilterActive {
                Divider()
                Button {
                    Haptics.tap()
                    colorFilter = nil
                    freeSlotFilter = .all
                } label: {
                    Label("Clear filter", systemImage: "xmark")
                }
            }
        } label: {
            Image(systemName: anyFilterActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(anyFilterActive ? skin.accentColor : skin.resolvedTextSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter timeline")
        .accessibilityLabel("Filter timeline")
    }

    @ViewBuilder
    private var paletteButton: some View {
        Button {
            Haptics.tap()
            onOpenPalette()
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "command")
                    .font(.system(size: 9, weight: .semibold))
                Text("K")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(skin.resolvedTextTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(skin.resolvedTextPrimary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .help("Open command palette (\u{2318}K)")
        .accessibilityLabel("Open command palette")
    }
}

#if DEBUG
#Preview {
    struct Wrap: View {
        @State var colorFilter: EventColorTag? = nil
        @State var freeSlotFilter: FreeSlotFilter = .all
        var body: some View {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let dates = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
            return MenuBarHeaderV2View(
                focusedDate: today,
                weekDates: dates,
                densityFor: { _ in 0.4 },
                usedColors: EventColorTag.allCases,
                colorFilter: $colorFilter,
                freeSlotFilter: $freeSlotFilter,
                onSelectDate: { _ in },
                onOpenPalette: {}
            )
            .frame(width: 360)
            .background(Color(white: 0.98))
        }
    }
    return Wrap()
}
#endif
