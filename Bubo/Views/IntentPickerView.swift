import SwiftUI

// MARK: - Intent Picker View

/// Shows recipe cards organized by suggestions and categories.
/// One View for all recipes — auto-generated from RecipeCatalog.
struct IntentPickerView: View {
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var optimizerService: OptimizerService
    var hasLocalEvents: Bool = true
    let onSelectRecipe: (ScheduleRecipe) -> Void
    var onAskAI: (() -> Void)? = nil

    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var suggestions: [ScheduleRecipe] {
        optimizerService.recipeMonitor?.suggestedRecipes ?? []
    }

    /// Top recipes ranked by HN score, falling back to hardcoded quick actions.
    private var quickActionRecipes: [ScheduleRecipe] {
        let ranked = optimizerService.usageTracker
            .topRecipeIds(limit: 6)
            .compactMap { RecipeCatalog.allRecipesById[$0] }
        return ranked.isEmpty ? RecipeCatalog.quickActions : ranked
    }

    private var isSearching: Bool { !searchText.isEmpty }

    /// Flat list of all recipes matching the search query (name, description, category).
    private var searchResults: [ScheduleRecipe] {
        let query = searchText.lowercased()
        return RecipeCatalog.allCategories.flatMap(\.recipes).filter { recipe in
            recipe.name.lowercased().contains(query)
            || recipe.description.lowercased().contains(query)
            || recipe.category.lowercased().contains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                // Unified search + AI input
                unifiedSearchField

                if isSearching {
                    // Search results — recipes first, AI fallback
                    searchResultsSection
                } else {
                    // Contextual suggestions first (most relevant)
                    if !suggestions.isEmpty {
                        suggestionsSection
                            .staggeredEntrance(index: 0)
                            .eventScrollTransition()
                    }

                    // Quick actions — HN-ranked by usage, falls back to defaults
                    quickActionsSection
                        .staggeredEntrance(index: 1)
                        .eventScrollTransition()

                    // All categories (expandable)
                    allCategoriesSection
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Unified Search + AI Field

    private var unifiedSearchField: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "sparkles")
                .foregroundStyle(isSearchFocused ? skin.accentColor : skin.resolvedTextTertiary)
                .font(.caption)
                .accessibilityHidden(true)
                .animation(skin.resolvedMicroAnimation, value: isSearchFocused)

            TextField("Find focus time, rearrange tasks, or ask anything…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .focused($isSearchFocused)
                .onSubmit {
                    // If no recipe matches, treat as AI query
                    if searchResults.isEmpty && !searchText.isEmpty {
                        onAskAI?()
                    } else if searchResults.count == 1 {
                        onSelectRecipe(searchResults[0])
                    }
                }
                .accessibilityLabel("Search recipes or ask AI")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .skinPlatter(skin)
        .skinPlatterDepth(skin)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(
                    isSearchFocused
                        ? skin.accentColor.opacity(0.3)
                        : Color.clear,
                    lineWidth: DS.Border.standard
                )
        )
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if searchResults.isEmpty {
                // No recipe match — offer AI as the action
                if onAskAI != nil {
                    VStack(spacing: DS.Spacing.md) {
                        Image(systemName: "sparkles")
                            .font(.title2)
                            .foregroundStyle(skin.accentColor)
                        Text("No recipes match \u{201C}\(searchText)\u{201D}")
                            .font(.subheadline)
                            .foregroundStyle(skin.resolvedTextSecondary)

                        Button {
                            onAskAI?()
                        } label: {
                            Label("Ask AI instead", systemImage: "sparkles")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.action(role: .primary, size: .compact))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.xxxl)
                } else {
                    VStack(spacing: DS.Spacing.md) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(skin.resolvedTextTertiary)
                        Text("No recipes found")
                            .font(.subheadline)
                            .foregroundStyle(skin.resolvedTextSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.xxxl)
                }
            } else {
                sectionHeader("\(searchResults.count) results")

                VStack(spacing: DS.Spacing.xs) {
                    ForEach(searchResults) { recipe in
                        RecipeCardView(recipe: recipe, style: .snippet, onTap: onSelectRecipe)
                    }
                }

                // AI fallback at the bottom of results
                if onAskAI != nil {
                    Button { onAskAI?() } label: {
                        HStack(spacing: DS.Spacing.sm) {
                            Image(systemName: "sparkles")
                                .font(.caption)
                                .foregroundStyle(skin.accentColor)
                            Text("Not what you need? Ask AI")
                                .font(.caption)
                                .foregroundStyle(skin.resolvedTextSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.top, DS.Spacing.sm)
                }
            }
        }
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            sectionHeader("Quick Actions")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.sm), count: 3), spacing: DS.Spacing.sm) {
                ForEach(quickActionRecipes) { recipe in
                    RecipeCardView(recipe: recipe, style: .quick, onTap: onSelectRecipe)
                }
            }
        }
    }

    // MARK: - Suggestions

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "lightbulb.max")
                    .font(.caption2)
                    .foregroundStyle(skin.accentColor)
                sectionHeader("Suggested", color: skin.accentColor)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Spacing.sm), GridItem(.flexible(), spacing: DS.Spacing.sm)], spacing: DS.Spacing.sm) {
                ForEach(suggestions) { recipe in
                    RecipeCardView(recipe: recipe, style: .suggested, onTap: onSelectRecipe)
                }
            }
        }
    }


    // MARK: - All Categories

    private var allCategoriesSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            sectionHeader("All Recipes")

            VStack(spacing: DS.Spacing.sm) {
                ForEach(RecipeCatalog.allCategories) { category in
                    CategorySection(
                        category: category,
                        hasLocalEvents: hasLocalEvents,
                        onSelectRecipe: onSelectRecipe
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, color: Color? = nil) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(color ?? skin.resolvedTextSecondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Recipe Card View

struct RecipeCardView: View {
    @Environment(\.activeSkin) private var skin
    let recipe: ScheduleRecipe
    let style: CardStyle
    var dimmed: Bool = false
    let onTap: (ScheduleRecipe) -> Void

    @State private var isHovered = false

    enum CardStyle {
        case quick       // compact grid card
        case suggested   // wider, highlighted
        case list        // full-width row
        case snippet     // event-row style — accent bar + title/description
    }

    var body: some View {
        Button {
            Haptics.tap()
            onTap(recipe)
        } label: {
            switch style {
            case .quick:
                quickLayout
            case .suggested:
                suggestedLayout
            case .list:
                listLayout
            case .snippet:
                snippetLayout
            }
        }
        .buttonStyle(RecipeCardButtonStyle(skin: skin))
        .onHover { hovering in
            withAnimation(skin.resolvedMicroAnimation) {
                isHovered = hovering
            }
        }
        .opacity(dimmed ? 0.45 : 1.0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recipe.name)
        .accessibilityHint(recipe.description)
        .accessibilityAddTraits(.isButton)
    }

    private var categoryDotColor: Color {
        DS.Colors.categoryPalette[recipe.categoryColorIndex]
    }

    private var quickLayout: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Circle()
                .fill(categoryDotColor)
                .frame(width: DS.Size.recipeDotSize, height: DS.Size.recipeDotSize)

            Text(recipe.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(skin.resolvedTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .skinPlatter(skin)
        .skinPlatterDepth(skin)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .fill(isHovered ? skin.resolvedHoverFill : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(
                    isHovered ? skin.accentColor.opacity(DS.Opacity.glassBorder) : .clear,
                    lineWidth: DS.Border.standard
                )
        )
        .shadow(
            color: isHovered ? skin.resolvedHoverShadowColor : skin.resolvedShadowColor,
            radius: isHovered ? skin.hoverShadowRadius : skin.shadowRadius,
            y: isHovered ? skin.hoverShadowY : skin.shadowY
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
    }

    private var suggestedLayout: some View {
        HStack(spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(recipe.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextPrimary)
                Text(recipe.description)
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .fill(skin.accentColor.opacity(isHovered ? DS.Opacity.mediumFill : DS.Opacity.lightFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(skin.accentColor.opacity(DS.Opacity.glassBorder), lineWidth: DS.Border.thin)
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
    }

    private var listLayout: some View {
        HStack(spacing: DS.Spacing.sm) {
            Circle()
                .fill(categoryDotColor.opacity(0.7))
                .frame(width: DS.Size.recipeDotSize, height: DS.Size.recipeDotSize)
                .frame(width: DS.Size.iconLarge)

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(recipe.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(skin.resolvedTextPrimary)
                if !recipe.description.isEmpty {
                    Text(recipe.description)
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: DS.Size.iconSmall))
                .foregroundStyle(skin.resolvedTextTertiary)
        }
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .fill(isHovered ? skin.resolvedHoverFill : .clear)
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
    }

    private var snippetLayout: some View {
        HStack(alignment: .center, spacing: 0) {
            // Category dot
            Circle()
                .fill(categoryDotColor)
                .frame(width: DS.Size.recipeDotSize, height: DS.Size.recipeDotSize)
                .frame(width: DS.Size.controlHeight)
                .padding(.trailing, DS.Spacing.sm)

            // Title + description
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(recipe.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(skin.resolvedTextPrimary)
                    .lineLimit(1)

                Text(recipe.description)
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DS.Spacing.md)

            Image(systemName: "chevron.right")
                .font(.system(size: DS.Size.iconSmall))
                .foregroundStyle(skin.resolvedTextTertiary)
        }
        .frame(minHeight: DS.Size.eventRowMinHeight)
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.sm)
        .background(
            ZStack {
                SkinPlatterBackground(skin: skin)
                Rectangle()
                    .fill(isHovered ? skin.resolvedHoverFill : Color.clear)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(skin.platterBorderOpacity * 1.5),
                            .white.opacity(skin.platterBorderOpacity * 0.1),
                            .clear,
                            .white.opacity(skin.platterBorderOpacity * 0.4)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: DS.Border.thin
                )
        )
        .shadow(
            color: isHovered ? skin.resolvedHoverShadowColor : skin.resolvedShadowColor,
            radius: isHovered ? skin.hoverShadowRadius : skin.shadowRadius,
            y: isHovered ? skin.hoverShadowY : skin.shadowY
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
    }
}

// MARK: - Recipe Card Button Style

private struct RecipeCardButtonStyle: ButtonStyle {
    let skin: SkinDefinition

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(skin.resolvedMicroAnimation, value: configuration.isPressed)
    }
}

// MARK: - Category Section

private struct CategorySection: View {
    @Environment(\.activeSkin) private var skin
    let category: RecipeCatalog.Category
    var hasLocalEvents: Bool = true
    let onSelectRecipe: (ScheduleRecipe) -> Void

    @State private var isExpanded = false

    private var categoryColor: Color {
        guard let first = category.recipes.first else { return skin.accentColor }
        return DS.Colors.categoryPalette[first.categoryColorIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.tap()
                isExpanded.toggle()
            } label: {
                HStack(alignment: .center, spacing: 0) {
                    // Accent bar
                    Capsule()
                        .fill(categoryColor)
                        .frame(width: DS.Size.accentBarWidth, height: DS.Size.accentBarHeight)
                        .padding(.trailing, DS.Spacing.md)
                        .shadow(color: categoryColor.opacity(skin.shadowOpacity * 4), radius: skin.shadowRadius * 0.5)

                    Text(category.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(skin.resolvedTextPrimary)

                    Spacer()

                    Text("\(category.recipes.count)")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xxs)
                        .background(skin.resolvedTextTertiary.opacity(DS.Opacity.lightFill))
                        .clipShape(Capsule())

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: DS.Size.iconSmall, weight: .semibold))
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .padding(.leading, DS.Spacing.xs)
                }
                .frame(minHeight: DS.Size.eventRowMinHeight)
                .padding(.vertical, DS.Spacing.sm)
                .padding(.horizontal, DS.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(category.name), \(category.recipes.count) recipes")
            .accessibilityHint(isExpanded ? "Double-tap to collapse" : "Double-tap to expand")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                SkinSeparator()
                    .padding(.horizontal, DS.Spacing.md)

                VStack(spacing: 0) {
                    ForEach(category.recipes) { recipe in
                        RecipeCardView(
                            recipe: recipe,
                            style: .list,
                            dimmed: false,
                            onTap: onSelectRecipe
                        )
                    }
                }
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.bottom, DS.Spacing.sm)
            }
        }
        .background(SkinPlatterBackground(skin: skin))
        .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(skin.platterBorderOpacity * 1.5),
                            .white.opacity(skin.platterBorderOpacity * 0.1),
                            .clear,
                            .white.opacity(skin.platterBorderOpacity * 0.4)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: DS.Border.thin
                )
        )
        .shadow(color: skin.resolvedShadowColor, radius: skin.shadowRadius, y: skin.shadowY)
    }
}
