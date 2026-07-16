import SwiftUI
import BuboDomain

/// Native grouped Form — same Settings.app vocabulary as `GeneralTabView`.
/// The skin grid and wallpaper pickers live inside native sections instead
/// of full-width `SettingsPlatter` cards.
struct AppearanceTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(\.activeSkin) private var skin

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: DS.Grid.skinCardMinWidth), spacing: DS.Grid.skinCardSpacing)], spacing: 8) {
                        ForEach(SkinCatalog.builtInSkins) { skin in
                            let isSelected = settings.selectedSkinID == skin.id
                            Button {
                                Haptics.tap()
                                withAnimation(DS.Animation.smoothSpring) {
                                    settings.selectedSkinID = skin.id
                                }
                            } label: {
                                SkinPreviewCard(skin: skin, isSelected: isSelected)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Theme: \(skin.displayName)\(skin.author != "Bubo" ? " by \(skin.author)" : "")")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }

                    CustomSkinsSection(settings: settings)
                }
            } header: {
                Text("Skin")
            }

            Section {
                WallpaperSectionView()
            } header: {
                Text("Background")
            }

            Section {
                BackgroundPhotoSection(settings: settings)
            }
        }
        .formStyle(.grouped)
    }
}
