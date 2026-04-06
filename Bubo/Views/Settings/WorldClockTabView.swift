import SwiftUI

struct WorldClockTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(\.activeSkin) private var skin
    @State private var searchText = ""

    private var filteredCities: [WorldClockCity] {
        if searchText.isEmpty {
            return WorldClockCity.allCities
        }
        let query = searchText.lowercased()
        return WorldClockCity.allCities.filter {
            $0.city.lowercased().contains(query) ||
            $0.country.lowercased().contains(query)
        }
    }

    private var selectedCities: [WorldClockCity] {
        settings.worldClockCityIDs.compactMap { WorldClockCity.city(forID: $0) }
    }

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
                SettingsPlatter("World Clock") {
                    Toggle("Show world clock strip", isOn: $settings.isWorldClockEnabled)

                    if settings.isWorldClockEnabled {
                        Text("Displays a row of time pills on the main screen and event creation.")
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextSecondary)
                    }
                }

                if settings.isWorldClockEnabled {
                    // Selected cities
                    if !selectedCities.isEmpty {
                        SettingsPlatter("Selected Cities") {
                            VStack(spacing: 0) {
                                ForEach(Array(selectedCities.enumerated()), id: \.element.id) { index, city in
                                    if index > 0 {
                                        SkinSeparator().padding(.leading, DS.Spacing.sm)
                                    }
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(city.city)
                                                .font(.body)
                                            Text(city.country)
                                                .font(.caption)
                                                .foregroundStyle(skin.resolvedTextSecondary)
                                        }

                                        Spacer()

                                        Text(city.timezoneID)
                                            .font(.caption2)
                                            .foregroundStyle(skin.resolvedTextTertiary)

                                        // Reorder buttons
                                        Button {
                                            Haptics.tap()
                                            withAnimation(DS.Animation.smoothSpring) {
                                                settings.worldClockCityIDs.swapAt(index, index - 1)
                                            }
                                        } label: {
                                            Image(systemName: "chevron.up")
                                                .font(.caption2)
                                                .foregroundStyle(skin.resolvedTextSecondary)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(index == 0)
                                        .opacity(index == 0 ? 0.3 : 1)
                                        .accessibilityLabel("Move \(city.city) up")
                                        .help("Move up")

                                        Button {
                                            Haptics.tap()
                                            withAnimation(DS.Animation.smoothSpring) {
                                                settings.worldClockCityIDs.swapAt(index, index + 1)
                                            }
                                        } label: {
                                            Image(systemName: "chevron.down")
                                                .font(.caption2)
                                                .foregroundStyle(skin.resolvedTextSecondary)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(index == selectedCities.count - 1)
                                        .opacity(index == selectedCities.count - 1 ? 0.3 : 1)
                                        .accessibilityLabel("Move \(city.city) down")
                                        .help("Move down")

                                        Button {
                                            Haptics.tap()
                                            withAnimation(DS.Animation.smoothSpring) {
                                                settings.worldClockCityIDs.removeAll { $0 == city.id }
                                            }
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundStyle(skin.resolvedDestructiveColor)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Remove \(city.city)")
                                        .help("Remove \(city.city) from world clock")
                                    }
                                    .padding(.vertical, DS.Spacing.sm)
                                    .padding(.horizontal, DS.Spacing.sm)
                                }
                            }
                        }
                    }

                    // City picker
                    SettingsPlatter("Add Cities") {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(skin.resolvedTextSecondary)
                            TextField("Search cities or countries\u{2026}", text: $searchText)
                                .textFieldStyle(.plain)
                        }
                        .padding(DS.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Spacing.sm, style: .continuous)
                                .fill(DS.Colors.textPrimary.opacity(DS.Opacity.subtleFill))
                        )

                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredCities) { city in
                                    let isAdded = settings.worldClockCityIDs.contains(city.id)
                                    Button {
                                        withAnimation(DS.Animation.smoothSpring) {
                                            if isAdded {
                                                settings.worldClockCityIDs.removeAll { $0 == city.id }
                                            } else {
                                                settings.worldClockCityIDs.append(city.id)
                                            }
                                        }
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(city.city)
                                                    .font(.body)
                                                    .foregroundStyle(skin.resolvedTextPrimary)
                                                Text(city.country)
                                                    .font(.caption)
                                                    .foregroundStyle(skin.resolvedTextSecondary)
                                            }

                                            Spacer()

                                            if isAdded {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(skin.accentColor)
                                            }
                                        }
                                        .padding(.vertical, DS.Spacing.xs)
                                        .padding(.horizontal, DS.Spacing.sm)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    SkinSeparator()
                                        .padding(.leading, DS.Spacing.sm)
                                }
                            }
                        }
                        .frame(maxHeight: 300)
                    }
                }
            }
            .padding(DS.Spacing.xl)
        }
        .animation(DS.Animation.smoothSpring, value: settings.isWorldClockEnabled)
    }
}
