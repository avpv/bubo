import SwiftUI

// MARK: - Intent Picker View

/// Shows recipe cards organized by suggestions and categories.
/// One View for all recipes — auto-generated from RecipeCatalog.
struct IntentPickerView: View {
    @Environment(\.activeSkin) private var skin
    var optimizerService: OptimizerService
    var hasLocalEvents: Bool = true
    let onSelectRecipe: (ScheduleRecipe) -> Void
    var onAskAI: (() -> Void)? = nil

    private var suggestions: [ScheduleRecipe] {
        optimizerService.recipeMonitor?.suggestedRecipes ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                // AI assistant entry point
                if onAskAI != nil {
                    askAISection
                }

                // Contextual suggestions (condition-based)
                if !suggestions.isEmpty {
                    suggestionsSection
                }

                // Quick actions grid — split into creative + planning
                quickActionsSection

                // All categories (expandable)
                allCategoriesSection
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Ask AI

    private var askAISection: some View {
        Button { onAskAI?() } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundStyle(skin.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask AI")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(skin.resolvedTextPrimary)
                    Text("Describe what you want in your own words")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
            .padding(DS.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius)
                    .fill(
                        LinearGradient(
                            colors: [skin.accentColor.opacity(0.12), skin.accentColor.opacity(0.04)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius)
                    .strokeBorder(skin.accentColor.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Suggestions

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Label("Suggested for you", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(skin.accentColor)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Spacing.sm) {
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
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            // Creative recipes — always work
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Create Blocks")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextSecondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Spacing.sm) {
                    ForEach(creativeActions) { recipe in
                        RecipeCardView(recipe: recipe, style: .quick, onTap: onSelectRecipe)
                    }
                }
            }

            // Planning recipes — need existing tasks
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack(spacing: DS.Spacing.xs) {
                    Text("Organize Tasks")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(skin.resolvedTextSecondary)

                    if !hasLocalEvents {
                        Text("needs tasks")
                            .font(.caption2)
                            .foregroundStyle(skin.resolvedTextTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(skin.resolvedTextTertiary.opacity(0.12))
                            )
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Spacing.sm) {
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
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text("All Recipes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(skin.resolvedTextSecondary)

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
        Button { onTap(recipe) } label: {
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
        .onHover { isHovered = $0 }
        .opacity(dimmed ? 0.45 : 1.0)
    }

    private var quickLayout: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Image(systemName: recipe.icon)
                .font(.system(size: 18))
                .foregroundStyle(skin.accentColor)
            Text(recipe.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(skin.resolvedTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(DS.Spacing.sm)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))
    }

    private var suggestedLayout: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: recipe.icon)
                .font(.system(size: 20))
                .foregroundStyle(skin.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
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
        .padding(DS.Spacing.sm)
        .background(suggestedBackground)
        .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))
    }

    private var listLayout: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: recipe.icon)
                .font(.caption)
                .foregroundStyle(skin.accentColor)
                .frame(width: 20)

            Text(recipe.name)
                .font(.caption)
                .foregroundStyle(skin.resolvedTextPrimary)

            Spacer()

            if !recipe.params.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(skin.resolvedTextTertiary)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .padding(.horizontal, DS.Spacing.sm)
        .background(isHovered ? skin.accentColor.opacity(0.05) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius)
            .fill(isHovered ? AnyShapeStyle(skin.accentColor.opacity(0.1)) : AnyShapeStyle(skin.resolvedPlatterMaterial.opacity(0.5)))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius)
                    .strokeBorder(isHovered ? skin.accentColor.opacity(0.3) : .clear, lineWidth: 1)
            )
    }

    private var suggestedBackground: some View {
        RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius)
            .fill(skin.accentColor.opacity(isHovered ? 0.15 : 0.08))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Size.previewSmallRadius)
                    .strokeBorder(skin.accentColor.opacity(0.25), lineWidth: 1)
            )
    }
}

// MARK: - Category Section

private struct CategorySection: View {
    @Environment(\.activeSkin) private var skin
    let category: RecipeCatalog.Category
    var hasLocalEvents: Bool = true
    let onSelectRecipe: (ScheduleRecipe) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Button {
                withAnimation(DS.Animation.smoothSpring) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: category.icon)
                        .font(.caption)
                        .foregroundStyle(skin.accentColor)
                        .frame(width: 16)

                    Text(category.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(skin.resolvedTextPrimary)

                    Spacer()

                    Text("\(category.recipes.count)")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(skin.resolvedTextTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, DS.Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
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
                .padding(.leading, DS.Spacing.lg)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(DS.Spacing.sm)
        .skinPlatter(skin)
        .skinPlatterDepth(skin)
    }
}
