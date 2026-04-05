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
    @Environment(\.activeSkin) private var activeSkin

    var body: some View {
        VStack(spacing: 4) {
            // Mini preview showing skin's visual identity
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: DS.Size.previewCardRadius)
                    .fill(skin.prefersDarkTint
                        ? DS.Colors.overlayBackground.opacity(0.88)
                        : DS.Colors.onOverlay.opacity(0.95)
                    )

                // Skin gradient
                RoundedRectangle(cornerRadius: DS.Size.previewCardRadius)
                    .fill(skin.previewGradient)
                    .opacity(0.8)

                // Mini UI mockup
                VStack(spacing: DS.Spacing.xxs) {
                    // Header bar
                    RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius)
                        .fill(skin.accentColor.opacity(DS.Opacity.overlayLight))
                        .frame(height: DS.Size.accentBarWidth)
                        .padding(.horizontal, DS.Spacing.pillVertical)

                    // Event rows
                    ForEach(0..<3, id: \.self) { i in
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: DS.Size.previewMicroRadius)
                                .fill(skin.accentColor)
                                .frame(width: DS.Spacing.xxs, height: 5)
                            RoundedRectangle(cornerRadius: DS.Size.previewMicroRadius)
                                .fill(DS.Colors.textPrimary.opacity(DS.Opacity.strongFill - Double(i) * 0.05))
                                .frame(height: 5)
                        }
                        .padding(.horizontal, DS.Spacing.pillVertical)
                    }
                }
                .padding(.vertical, DS.Spacing.xs)
            }
            .frame(height: DS.Size.previewCardHeight)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.previewCardRadius)
                    .strokeBorder(
                        isSelected ? skin.accentColor : DS.Colors.textPrimary.opacity(0.1),
                        lineWidth: isSelected ? DS.Border.selection : DS.Border.thin
                    )
            )
            .shadow(
                color: isSelected ? skin.accentColor.opacity(0.3) : .clear,
                radius: isSelected ? skin.shadowRadius * 0.5 : 0
            )

            VStack(spacing: 0) {
                Text(skin.displayName)
                    .font(.caption2)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? activeSkin.resolvedTextPrimary : activeSkin.resolvedTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if skin.author != "Bubo" {
                    Text("by \(skin.author)")
                        .font(.caption2)
                        .foregroundStyle(activeSkin.resolvedTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }
}

// MARK: - Custom Skins Section

struct CustomSkinsSection: View {
    @Bindable var settings: ReminderSettings
    @Environment(\.activeSkin) private var skin
    @State private var customSkinLoader = CustomSkinLoader.shared
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SkinSeparator()

            HStack {
                Text("Community skins")
                    .font(.subheadline)
                    .foregroundStyle(skin.resolvedTextSecondary)
                Spacer()
                Button {
                    customSkinLoader.revealInFinder()
                } label: {
                    Label("Open folder", systemImage: "folder")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(skin.resolvedTextSecondary)
            }

            if !customSkinLoader.customSkins.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: DS.Grid.skinCardMinWidth), spacing: DS.Grid.skinCardSpacing)], spacing: 8) {
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
                Label("Import skin .json file\u{2026}", systemImage: "plus.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(skin.resolvedTextSecondary)
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
        panel.allowedContentTypes = [.json]
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
            importError = "Could not read the skin file. Make sure it is a valid skin .json file."
        }
    }
}



// MARK: - Background Photo Section

struct BackgroundPhotoSection: View {
    @Bindable var settings: ReminderSettings
    @Environment(\.activeSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Global Background Photo")
                    .font(.subheadline)
                    .foregroundStyle(skin.resolvedTextPrimary)
                Text("Overrides all themes and built-in wallpapers across the app")
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextSecondary)
            }

            if !settings.customBackgroundPhotoPath.isEmpty,
               let nsImage = NSImage(contentsOfFile: settings.customBackgroundPhotoPath) {
                // Preview
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 240)
                        .opacity(settings.customBackgroundPhotoOpacity)
                        .blur(radius: settings.customBackgroundPhotoBlur)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: DS.Spacing.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Spacing.sm)
                                .strokeBorder(DS.Colors.textPrimary.opacity(DS.Opacity.faintBorder), lineWidth: DS.Border.thin)
                        )

                    Button {
                        withAnimation(DS.Animation.smoothSpring) {
                            settings.customBackgroundPhotoPath = ""
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(skin.resolvedTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(DS.Spacing.pillVertical)
                }

                // Controls
                VStack(spacing: 4) {
                    HStack {
                        Text("Opacity")
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextSecondary)
                            .frame(width: 50, alignment: .leading)
                        Slider(value: $settings.customBackgroundPhotoOpacity, in: 0.05...1.0, step: 0.05)
                            .accessibilityLabel("Photo opacity")
                        Text("\(Int(settings.customBackgroundPhotoOpacity * 100))%")
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextSecondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                    HStack {
                        Text("Blur")
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextSecondary)
                            .frame(width: 50, alignment: .leading)
                        Slider(value: $settings.customBackgroundPhotoBlur, in: 0...10, step: 0.5)
                            .accessibilityLabel("Photo blur")
                        Text(String(format: "%.1f", settings.customBackgroundPhotoBlur))
                            .font(.caption)
                            .foregroundStyle(skin.resolvedTextSecondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }

            Button {
                choosePhoto()
            } label: {
                Label(
                    settings.customBackgroundPhotoPath.isEmpty
                        ? "Choose photo\u{2026}"
                        : "Change photo\u{2026}",
                    systemImage: "photo"
                )
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(skin.resolvedTextSecondary)

            Text("Recommended size: 720\u{00D7}1200 px (3:5)")
                .font(.caption2)
                .foregroundStyle(skin.resolvedTextTertiary)
        }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.title = "Choose Background Photo"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Copy to App Support so it persists
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let photosDir = appSupport.appendingPathComponent("Bubo/Photos", isDirectory: true)
        try? fileManager.createDirectory(at: photosDir, withIntermediateDirectories: true)

        let destination = photosDir.appendingPathComponent("background.\(url.pathExtension)")
        try? fileManager.removeItem(at: destination)

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            try fileManager.copyItem(at: url, to: destination)
            withAnimation(DS.Animation.smoothSpring) {
                settings.customBackgroundPhotoPath = destination.path
                // Photo and wallpaper are mutually exclusive
                settings.selectedWallpaperID = "none"
            }
        } catch {
            // Silently fail — user can try again
        }
    }
}

// MARK: - Wallpaper Section

struct WallpaperSectionView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(\.activeSkin) private var skin
    @State private var selectedCategory: WallpaperCategory = .solidColor

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Choose a background wallpaper")
                .font(.subheadline)
                .foregroundStyle(skin.resolvedTextSecondary)

            // Category picker
            Picker("Category", selection: $selectedCategory) {
                ForEach(WallpaperCategory.allCases) { category in
                    Label(category.displayName, systemImage: category.systemImage)
                        .tag(category)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Wallpaper grid for selected category
            let wallpapers = WallpaperCatalog.wallpapers(in: selectedCategory)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: DS.Grid.skinCardMinWidth), spacing: DS.Grid.skinCardSpacing)], spacing: 8) {
                ForEach(wallpapers) { wallpaper in
                    let isSelected = settings.selectedWallpaperID == wallpaper.id
                    Button {
                        withAnimation(DS.Animation.smoothSpring) {
                            settings.selectedWallpaperID = wallpaper.id
                            // Wallpaper and photo are mutually exclusive
                            if wallpaper.id != "none" {
                                settings.customBackgroundPhotoPath = ""
                            }
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
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
        }
    }
}

// MARK: - General Tab

struct GeneralTabView: View {
    @Environment(ReminderSettings.self) var settings
    @Environment(ReminderService.self) var reminderService
    @Environment(\.activeSkin) private var skin
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
                        .foregroundStyle(skin.resolvedWarningColor)
                        .font(.caption)
                }
            }

            SettingsPlatter {
                VStack(spacing: DS.Spacing.xs) {
                    HStack {
                        Spacer()
                        Text("Bubo \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedTextTertiary)
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        Link("GitHub Project", destination: URL(string: "https://github.com/avpv/bubo")!)
                            .font(.caption2)
                            .accessibilityHint("Opens in your web browser")
                        Spacer()
                    }
                }
            }
            }
            .padding(DS.Spacing.xl)
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
