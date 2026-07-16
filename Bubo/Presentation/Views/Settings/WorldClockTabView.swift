import SwiftUI
import BuboDomain

/// Native grouped Form — same Settings.app vocabulary as `GeneralTabView`.
/// Selected cities render as native rows (the Form owns separators and
/// row insets); the searchable picker keeps its own inner scroll region.
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

        Form {
            Section {
                Toggle("Show world clock", isOn: $settings.isWorldClockEnabled)
            } footer: {
                if settings.isWorldClockEnabled {
                    Text("Shows the selected cities' times as a line under the main screen's title.")
                }
            }

            if settings.isWorldClockEnabled {
                if !selectedCities.isEmpty {
                    Section {
                        ForEach(Array(selectedCities.enumerated()), id: \.element.id) { index, city in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(city.city)
                                        .font(DS.Typography.body(skin: skin))
                                    Text(city.country)
                                        .font(.footnote)
                                        .foregroundStyle(skin.resolvedTextSecondary)
                                }

                                Spacer()

                                Text(city.timezoneID)
                                    .font(.footnote)
                                    .foregroundStyle(skin.resolvedTextTertiary)

                                // Reorder buttons
                                Button {
                                    Haptics.tap()
                                    withAnimation(DS.Animation.smoothSpring) {
                                        settings.worldClockCityIDs.swapAt(index, index - 1)
                                    }
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .font(.footnote)
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
                                        .font(.footnote)
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
                        }
                    } header: {
                        Text("Selected Cities")
                    }
                }

                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(skin.resolvedTextSecondary)
                        TextField("Search cities or countries\u{2026}", text: $searchText)
                            .textFieldStyle(.plain)
                    }

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
                                                .font(DS.Typography.body(skin: skin))
                                                .foregroundStyle(skin.resolvedTextPrimary)
                                            Text(city.country)
                                                .font(.footnote)
                                                .foregroundStyle(skin.resolvedTextSecondary)
                                        }

                                        Spacer()

                                        if isAdded {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(skin.accentColor)
                                        }
                                    }
                                    .padding(.vertical, DS.Spacing.xs)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                SkinSeparator()
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                } header: {
                    Text("Add Cities")
                }
            }
        }
        .formStyle(.grouped)
        .animation(DS.Animation.smoothSpring, value: settings.isWorldClockEnabled)
    }
}
