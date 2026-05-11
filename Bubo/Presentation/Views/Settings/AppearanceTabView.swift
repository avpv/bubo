import SwiftUI

struct AppearanceTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(\.activeSkin) private var skin

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
                SettingsPlatter("Skin") {
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        Text("Choose a visual theme")
                            .font(.subheadline)
                            .foregroundStyle(skin.resolvedTextSecondary)
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
                }

                SettingsPlatter("Background") {
                    WallpaperSectionView()

                    SkinSeparator()
                        .padding(.vertical, DS.Spacing.xs)

                    BackgroundPhotoSection(settings: settings)
                }
            }
            .padding(DS.Spacing.xl)
        }
    }
}
