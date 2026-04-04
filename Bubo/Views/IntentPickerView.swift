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

                // Recently used — always shown, falls back to quick actions
                recentlySection
                    .staggeredEntrance(index: 1)

                // Contextual suggestions (condition-based)
                if !suggestions.isEmpty {
                    suggestionsSection
                        .staggeredEntrance(index: 2)
                }

                // All categories (expandable)
                allCategoriesSection
                    .staggeredEntrance(index: 3)
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

    // MARK: - Recently

    private var recentlySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            sectionHeader("Recently")

            let recipes = recentRecipes.isEmpty ? RecipeCatalog.quickActions : recentRecipes

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.sm), count: 3), spacing: DS.Spacing.sm) {
                ForEach(recipes) { recipe in
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

    private var quickLayout: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(recipe.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(skin.resolvedTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !recipe.description.isEmpty {
                Text(recipe.description)
                    .font(.system(size: 9))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
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
            // Accent bar — like EventRowView urgency bar
            Capsule()
                .fill(skin.accentColor)
                .frame(width: DS.Size.accentBarWidth, height: DS.Size.accentBarHeight)
                .padding(.trailing, DS.Spacing.md)
                .shadow(color: skin.accentColor.opacity(skin.shadowOpacity * 4), radius: skin.shadowRadius * 0.5)

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
                HStack(alignment: .center, spacing: 0) {
                    // Accent bar
                    Capsule()
                        .fill(skin.accentColor)
                        .frame(width: DS.Size.accentBarWidth, height: DS.Size.accentBarHeight)
                        .padding(.trailing, DS.Spacing.md)
                        .shadow(color: skin.accentColor.opacity(skin.shadowOpacity * 4), radius: skin.shadowRadius * 0.5)

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
                        .padding(.leading, DS.Spacing.xs)
                }
                .frame(minHeight: DS.Size.eventRowMinHeight)
                .padding(.vertical, DS.Spacing.sm)
                .padding(.horizontal, DS.Spacing.sm)
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
                            dimmed: false,
                            onTap: onSelectRecipe
                        )
                    }
                }
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.bottom, DS.Spacing.sm)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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
