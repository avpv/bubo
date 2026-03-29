import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct ThemeColorPreview: View {
    let colors: [Color]
    var size: CGFloat = 12

    var body: some View {
        if colors.count == 1 {
            Circle()
                .fill(colors[0])
                .frame(width: size, height: size)
        } else {
            Circle()
                .fill(
                    LinearGradient(
                        colors: colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Skin Preview Card

struct SkinPreviewCard: View {
    let skin: SkinDefinition
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 4) {
            // Mini preview showing skin's visual identity
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 6)
                    .fill(colorScheme == .dark
                        ? Color(white: 0.12)
                        : Color(white: 0.95)
                    )

                // Skin gradient
                RoundedRectangle(cornerRadius: 6)
                    .fill(skin.previewGradient)
                    .opacity(0.8)

                // Mini UI mockup
                VStack(spacing: 2) {
                    // Header bar
                    RoundedRectangle(cornerRadius: 2)
                        .fill(skin.accentColor.opacity(0.6))
                        .frame(height: 4)
                        .padding(.horizontal, 6)

                    // Event rows
                    ForEach(0..<3, id: \.self) { i in
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(skin.accentColor)
                                .frame(width: 2, height: 5)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.primary.opacity(0.2 - Double(i) * 0.05))
                                .frame(height: 5)
                        }
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 40)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isSelected ? skin.accentColor : Color.primary.opacity(0.1),
                        lineWidth: isSelected ? 2 : 0.5
                    )
            )
            .shadow(
                color: isSelected ? skin.accentColor.opacity(0.3) : .clear,
                radius: isSelected ? 4 : 0
            )

            VStack(spacing: 0) {
                Text(skin.displayName)
                    .font(.caption2)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.primary : .secondary)
                    .lineLimit(1)
                if skin.author != "Bubo" {
                    Text("by \(skin.author)")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Custom Skins Section

struct CustomSkinsSection: View {
    @Bindable var settings: ReminderSettings
    @State private var customSkinLoader = CustomSkinLoader.shared
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Divider()

            HStack {
                Text("Community skins")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    customSkinLoader.revealInFinder()
                } label: {
                    Label("Open folder", systemImage: "folder")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if !customSkinLoader.customSkins.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 94), spacing: 8)], spacing: 8) {
                    ForEach(customSkinLoader.customSkins) { skin in
                        let isSelected = settings.selectedSkinID == skin.id
                        Button {
                            withAnimation(DS.Animation.smoothSpring) {
                                settings.selectedSkinID = skin.id
                            }
                        } label: {
                            SkinPreviewCard(skin: skin, isSelected: isSelected)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                if settings.selectedSkinID == skin.id {
                                    settings.selectedSkinID = "system"
                                }
                                customSkinLoader.removeSkin(id: skin.id)
                            } label: {
                                Label("Remove skin", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Button {
                importSkin()
            } label: {
                Label("Import .buboskin file\u{2026}", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .alert("Import failed", isPresented: .init(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func importSkin() {
        let panel = NSOpenPanel()
        panel.title = "Import Bubo Skin"
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "buboskin") ?? .json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }

        var importedCount = 0
        for url in panel.urls {
            if customSkinLoader.importSkin(from: url) != nil {
                importedCount += 1
            }
        }

        if importedCount == 0 {
            importError = "Could not read the skin file. Make sure it is a valid .buboskin JSON file."
        }
    }
}

// MARK: - Wallpaper Section

struct WallpaperSectionView: View {
    @Environment(ReminderSettings.self) var settings
    @State private var selectedCategory: WallpaperCategory = .solidColor

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Choose a background wallpaper")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Category picker
            Picker("Category", selection: $selectedCategory) {
                ForEach(WallpaperCategory.allCases) { category in
                    Label(category.displayName, systemImage: category.systemImage)
                        .tag(category)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // "None" option
            let isNoneSelected = settings.selectedWallpaperID == "none"
            Button {
                withAnimation(DS.Animation.smoothSpring) {
                    settings.selectedWallpaperID = "none"
                }
            } label: {
                HStack(spacing: DS.Spacing.sm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(white: 0.12))
                            .frame(width: 32, height: 32)
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                isNoneSelected ? Color.accentColor : Color.primary.opacity(0.1),
                                lineWidth: isNoneSelected ? 2 : 0.5
                            )
                    )
                    Text("No wallpaper")
                        .font(.caption)
                        .foregroundStyle(isNoneSelected ? .primary : .secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            // Wallpaper grid for selected category
            let wallpapers = WallpaperCatalog.wallpapers(in: selectedCategory)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 94), spacing: 8)], spacing: 8) {
                ForEach(wallpapers) { wallpaper in
                    let isSelected = settings.selectedWallpaperID == wallpaper.id
                    Button {
                        withAnimation(DS.Animation.smoothSpring) {
                            settings.selectedWallpaperID = wallpaper.id
                        }
                    } label: {
                        WallpaperPreviewCard(wallpaper: wallpaper, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                }
            }

            if selectedCategory == .live {
                Label("Live wallpapers use animation and may increase energy usage", systemImage: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - General Tab

struct GeneralTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(ReminderService.self) var reminderService
    @State private var loginItemError: String?

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    settings.launchAtLogin = newValue
                } catch {
                    loginItemError = error.localizedDescription
                }
            }
        )
    }

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
            SettingsPlatter("Refresh") {
                Picker("Refresh interval", selection: $settings.syncIntervalMinutes) {
                    Text("1 minute").tag(1)
                    Text("3 minutes").tag(3)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
            }

            SettingsPlatter("Startup") {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
            }

            SettingsPlatter("Event Counter Badge") {
                Toggle("Show event count in menu bar", isOn: $settings.showBadgeCount)

                if settings.showBadgeCount {
                    Picker("Count mode", selection: $settings.badgeCountMode) {
                        ForEach(BadgeCountMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    if settings.badgeCountMode == .timeWindow {
                        Stepper(
                            "Time window: \(settings.badgeTimeWindowHours) h",
                            value: $settings.badgeTimeWindowHours,
                            in: 1...ReminderService.fetchWindowDays * 24
                        )
                    }
                }
            }

            SettingsPlatter("Skin") {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text("Choose a visual theme")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 94), spacing: 8)], spacing: 8) {
                        ForEach(SkinCatalog.builtInSkins) { skin in
                            let isSelected = settings.selectedSkinID == skin.id
                            Button {
                                withAnimation(DS.Animation.smoothSpring) {
                                    settings.selectedSkinID = skin.id
                                }
                            } label: {
                                SkinPreviewCard(skin: skin, isSelected: isSelected)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    CustomSkinsSection(settings: settings)
                }
            }

            SettingsPlatter("Wallpaper") {
                WallpaperSectionView()
            }

            if settings.selectedSkin.isClassic {
                SettingsPlatter("Background") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gradient overlay")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                            ForEach(AppBackgroundStyle.allCases) { style in
                                let isSelected = settings.backgroundStyle == style
                                Button {
                                    settings.backgroundStyle = style
                                } label: {
                                    VStack(spacing: 4) {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(style.previewGradient)
                                            .frame(height: 28)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .strokeBorder(
                                                        isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                                                        lineWidth: isSelected ? 2 : 0.5
                                                    )
                                            )
                                        Text(style.displayName)
                                            .font(.caption2)
                                            .foregroundStyle(isSelected ? .primary : .secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            SettingsPlatter("Status") {
                if let lastSync = reminderService.lastSyncDate {
                    LabeledContent("Last refresh") {
                        Text(lastSync.formatted())
                    }
                }

                LabeledContent("Calendar events") {
                    Text("\(reminderService.upcomingEvents.count)")
                }

                LabeledContent("Local events") {
                    Text("\(reminderService.localEvents.count)")
                }

                if reminderService.isUsingCache {
                    Label("Using cached data", systemImage: "internaldrive")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
            }

            SettingsPlatter {
                VStack(spacing: DS.Spacing.xs) {
                    HStack {
                        Spacer()
                        Text("Bubo \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        Link("GitHub Project", destination: URL(string: "https://github.com/avpv/bubo")!)
                            .font(.caption2)
                        Spacer()
                    }
                }
            }
            }
            .padding(20)
        }
        .onAppear {
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .alert("Cannot change login item", isPresented: .init(
            get: { loginItemError != nil },
            set: { if !$0 { loginItemError = nil } }
        )) {
            Button("OK") { loginItemError = nil }
        } message: {
            Text(loginItemError ?? "")
        }
    }
}
