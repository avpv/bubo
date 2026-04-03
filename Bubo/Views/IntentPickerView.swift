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

    private var suggestions: [ScheduleRecipe] {
        optimizerService.recipeMonitor?.suggestedRecipes ?? []
    }

    private var recentRecipes: [ScheduleRecipe] {
        optimizerService.usageTracker
            .topRecipeIds(limit: 6)
            .compactMap { RecipeCatalog.allRecipesById[$0] }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                // AI assistant entry point
                if onAskAI != nil {
                    askAISection
                        .staggeredEntrance(index: 0)
                }

                // Recently used (HN-ranked)
                if !recentRecipes.isEmpty {
                    recentlyUsedSection
                        .staggeredEntrance(index: 1)
                }

                // Contextual suggestions (condition-based)
                if !suggestions.isEmpty {
                    suggestionsSection
                        .staggeredEntrance(index: 2)
                }

                // Quick actions grid — split into creative + planning
                quickActionsSection
                    .staggeredEntrance(index: 3)

                // All categories (expandable)
                allCategoriesSection
                    .staggeredEntrance(index: 4)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Ask AI

    private var askAISection: some View {
        Button { onAskAI?() } label: {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: "sparkles")
                    .font(.system(size: DS.Size.headerIcon, weight: .medium))
                    .foregroundStyle(skin.accentColor)
                    .frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask AI")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(skin.resolvedTextPrimary)
                    Text("Describe what you want in your own words")
                        .font(.caption)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .padding(DS.Spacing.md)
            .skinPlatter(skin)
            .skinPlatterDepth(skin)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [skin.accentColor.opacity(0.3), skin.accentColor.opacity(0.08)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: DS.Border.standard
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask AI to plan your schedule")
        .accessibilityHint("Describe what you want in your own words")
    }

    // MARK: - Recently Used

    private var recentlyUsedSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            sectionHeader("Recently Used")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.sm), count: 3), spacing: DS.Spacing.sm) {
                ForEach(recentRecipes) { recipe in
                    RecipeCardView(recipe: recipe, style: .quick, onTap: onSelectRecipe)
                }
            }
        }
    }

    // MARK: - Suggestions

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(skin.accentColor)
                sectionHeader("Suggested for you", color: skin.accentColor)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Spacing.sm), GridItem(.flexible(), spacing: DS.Spacing.sm)], spacing: DS.Spacing.sm) {
                ForEach(suggestions) { recipe in
                    RecipeCardView(recipe: recipe, style: .suggested, onTap: onSelectRecipe)
                }
            }
        }
    }

    // MARK: - Quick Actions

    private var creativeActions: [ScheduleRecipe] {
        RecipeCatalog.quickActions.filter { $0.isCreative }
    }

    private var planningActions: [ScheduleRecipe] {
        RecipeCatalog.quickActions.filter { $0.needsExistingEvents }
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            // Creative recipes — always work
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                sectionHeader("Create Blocks")

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.sm), count: 3), spacing: DS.Spacing.sm) {
                    ForEach(creativeActions) { recipe in
                        RecipeCardView(recipe: recipe, style: .quick, onTap: onSelectRecipe)
                    }
                }
            }

            // Planning recipes — need existing tasks
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack(spacing: DS.Spacing.sm) {
                    sectionHeader("Organize Tasks")

                    if !hasLocalEvents {
                        Text("needs tasks")
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedTextTertiary)
                            .padding(.horizontal, DS.Spacing.pillHorizontal)
                            .padding(.vertical, DS.Spacing.xxs)
                            .adaptiveBadgeFill(skin.resolvedTextTertiary)
                            .clipShape(Capsule())
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.sm), count: 3), spacing: DS.Spacing.sm) {
                    ForEach(planningActions) { recipe in
                        RecipeCardView(
                            recipe: recipe,
                            style: .quick,
                            dimmed: !hasLocalEvents,
                            onTap: onSelectRecipe
                        )
                    }
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(color ?? skin.resolvedTextSecondary)
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
            }
        }
        .buttonStyle(.plain)
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

    private var quickLayout: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Spacer(minLength: 0)
            Text(recipe.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(skin.resolvedTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(DS.Spacing.md)
        .skinPlatter(skin)
        .skinPlatterDepth(skin)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(
                    isHovered ? skin.accentColor.opacity(DS.Opacity.glassBorder) : .clear,
                    lineWidth: DS.Border.standard
                )
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
            Text(recipe.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(skin.resolvedTextPrimary)

            Spacer()

            if !recipe.params.isEmpty {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: DS.Size.iconSmall))
                    .foregroundStyle(skin.resolvedTextTertiary)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: DS.Size.iconSmall))
                .foregroundStyle(skin.resolvedTextTertiary)
        }
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .fill(isHovered ? skin.accentColor.opacity(DS.Opacity.subtleFill) : .clear)
        )
    }
}

// MARK: - Category Section

private struct CategorySection: View {
    @Environment(\.activeSkin) private var skin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let category: RecipeCatalog.Category
    var hasLocalEvents: Bool = true
    let onSelectRecipe: (ScheduleRecipe) -> Void

    @State private var isExpanded = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.tap()
                withAnimation(reduceMotion ? nil : DS.Animation.smoothSpring) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: DS.Spacing.sm) {
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

                    Image(systemName: "chevron.right")
                        .font(.system(size: DS.Size.iconSmall, weight: .semibold))
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(DS.Spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(skin.resolvedMicroAnimation) {
                    isHovered = hovering
                }
            }
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
                            dimmed: recipe.needsExistingEvents && !hasLocalEvents,
                            onTap: onSelectRecipe
                        )
                    }
                }
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.bottom, DS.Spacing.sm)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .skinPlatter(skin)
        .skinPlatterDepth(skin)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous)
                .strokeBorder(
                    isHovered && !isExpanded ? skin.accentColor.opacity(DS.Opacity.faintBorder) : .clear,
                    lineWidth: DS.Border.standard
                )
        )
    }
}
