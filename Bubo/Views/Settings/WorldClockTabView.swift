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
        settings.worldClockCityIDs.compactMap { id in
            WorldClockCity.allCities.first { $0.timezoneID == id }
        }
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
                            .foregroundStyle(.secondary)
                    }
                }

                if settings.isWorldClockEnabled {
                    // Selected cities
                    if !selectedCities.isEmpty {
                        SettingsPlatter("Selected Cities") {
                            // HIG: User-managed lists should support reordering
                            List {
                                ForEach(selectedCities) { city in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(city.city)
                                                .font(.body)
                                            Text(city.country)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        Text(city.timezoneID)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)

                                        Button {
                                            withAnimation(DS.Animation.smoothSpring) {
                                                settings.worldClockCityIDs.removeAll { $0 == city.timezoneID }
                                            }
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundStyle(skin.resolvedDestructiveColor)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Remove \(city.city)")
                                        .help("Remove \(city.city) from world clock")
                                    }
                                }
                                .onMove { from, to in
                                    settings.worldClockCityIDs.move(fromOffsets: from, toOffset: to)
                                }
                            }
                            .listStyle(.plain)
                            .frame(maxHeight: CGFloat(selectedCities.count) * 50)
                            .scrollContentBackground(.hidden)
                        }
                    }

                    // City picker
                    SettingsPlatter("Add Cities") {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Search cities...", text: $searchText)
                                .textFieldStyle(.plain)
                        }
                        .padding(DS.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )

                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredCities) { city in
                                    let isAdded = settings.worldClockCityIDs.contains(city.timezoneID)
                                    Button {
                                        withAnimation(DS.Animation.smoothSpring) {
                                            if isAdded {
                                                settings.worldClockCityIDs.removeAll { $0 == city.timezoneID }
                                            } else {
                                                settings.worldClockCityIDs.append(city.timezoneID)
                                            }
                                        }
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(city.city)
                                                    .font(.body)
                                                    .foregroundStyle(.primary)
                                                Text(city.country)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
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

                                    Divider()
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
