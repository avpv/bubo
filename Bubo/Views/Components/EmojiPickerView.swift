import SwiftUI

/// A simplified Telegram-style emoji picker that appears as a popover.
struct EmojiPickerView: View {
    var onSelect: (String) -> Void

    @State private var searchText = ""
    @State private var selectedCategory = 0
    @Environment(\.activeSkin) private var skin

    private static let categories: [(icon: String, title: String, emojis: [String])] = [
        ("clock", "Recent", ["👍", "❤️", "😂", "🔥", "✅", "👀", "🎉", "💯"]),
        ("face.smiling", "Smileys", [
            "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂",
            "🙂", "😊", "😇", "🥰", "😍", "🤩", "😘", "😗",
            "😋", "😛", "😜", "🤪", "😝", "🤑", "🤗", "🤭",
            "🤫", "🤔", "🫡", "🤐", "🤨", "😐", "😑", "😶",
            "😏", "😒", "🙄", "😬", "🤥", "😌", "😔", "😪",
            "🤤", "😴", "😷", "🤒", "🤕", "🤢", "🤮", "🥵",
            "🥶", "😱", "😨", "😰", "😥", "😢", "😭", "😤",
            "😡", "🤬", "😈", "👿", "💀", "☠️", "💩", "🤡",
        ]),
        ("hand.raised", "Gestures", [
            "👋", "🤚", "🖐️", "✋", "🖖", "👌", "🤌", "🤏",
            "✌️", "🤞", "🫰", "🤟", "🤘", "🤙", "👈", "👉",
            "👆", "🖕", "👇", "☝️", "🫵", "👍", "👎", "✊",
            "👊", "🤛", "🤜", "👏", "🙌", "🫶", "👐", "🤲",
            "🙏", "💪", "🦾", "🫂", "❤️", "🧡", "💛", "💚",
        ]),
        ("leaf", "Nature", [
            "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼",
            "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔",
            "🌸", "🌺", "🌻", "🌹", "🌷", "🌱", "🌲", "🌳",
            "☀️", "🌙", "⭐", "🌈", "☁️", "⚡", "❄️", "🔥",
        ]),
        ("fork.knife", "Food", [
            "🍎", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐",
            "🍑", "🥑", "🍕", "🍔", "🍟", "🌮", "🍣", "🍜",
            "☕", "🍵", "🧃", "🍺", "🍷", "🥤", "🧁", "🍰",
        ]),
        ("sportscourt", "Activity", [
            "⚽", "🏀", "🏈", "⚾", "🎾", "🏐", "🎮", "🎯",
            "🏆", "🥇", "🎪", "🎭", "🎨", "🎬", "🎤", "🎧",
            "🎵", "🎶", "💃", "🕺", "🏃", "🚴", "🏊", "⛷️",
        ]),
        ("briefcase", "Objects", [
            "📱", "💻", "⌨️", "🖥️", "📷", "📸", "💡", "🔧",
            "📌", "📎", "✏️", "📝", "📅", "📊", "📈", "💰",
            "✈️", "🚀", "🏠", "🏢", "⏰", "🔔", "📣", "💬",
        ]),
        ("flag", "Symbols", [
            "✅", "❌", "⭕", "❗", "❓", "💯", "🔴", "🟢",
            "🔵", "⚪", "⚫", "🟡", "♻️", "⚠️", "🚫", "💤",
            "⬆️", "⬇️", "➡️", "⬅️", "↩️", "🔄", "🆕", "🆗",
        ]),
    ]

    private var filteredEmojis: [String] {
        guard !searchText.isEmpty else {
            return Self.categories[selectedCategory].emojis
        }
        // Simple search: show all emojis from all categories
        return Self.categories.flatMap(\.emojis)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .font(.caption)
                TextField("Search emoji", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(skin.resolvedTextTertiary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .skinPlatter(skin)
            .clipShape(RoundedRectangle(cornerRadius: DS.Size.cornerRadius, style: .continuous))
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.xs)

            // Category tabs
            if searchText.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xxs) {
                        ForEach(Array(Self.categories.enumerated()), id: \.offset) { index, category in
                            Button {
                                selectedCategory = index
                            } label: {
                                Image(systemName: category.icon)
                                    .font(.system(size: 13))
                                    .foregroundStyle(selectedCategory == index ? skin.accentColor : skin.resolvedTextTertiary)
                                    .frame(width: 28, height: 24)
                                    .background(
                                        selectedCategory == index
                                            ? skin.accentColor.opacity(0.15)
                                            : Color.clear
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: max(DS.Size.cornerRadius - 3, 3), style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help(category.title)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.sm)
                }
                .padding(.vertical, DS.Spacing.xxs)

                // Category title
                Text(Self.categories[selectedCategory].title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(skin.resolvedTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.top, DS.Spacing.xs)
            }

            // Emoji grid
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 8), spacing: 2) {
                    ForEach(filteredEmojis, id: \.self) { emoji in
                        Button {
                            onSelect(emoji)
                        } label: {
                            Text(emoji)
                                .font(.title2)
                                .frame(width: DS.Size.emojiCellSize, height: DS.Size.emojiCellSize)
                                .background(Color.clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xs)
            }
        }
        .frame(width: DS.Size.emojiPickerWidth, height: DS.Size.emojiPickerHeight)
        .skinPlatter(skin)
    }
}

/// A button that shows the emoji picker popover and inserts selected emoji into a text binding.
struct EmojiPickerButton: View {
    @Binding var text: String
    @State private var showPicker = false
    @Environment(\.activeSkin) private var skin

    var body: some View {
        Button {
            showPicker.toggle()
        } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: DS.Size.iconLarge))
                .foregroundStyle(showPicker ? skin.accentColor : skin.resolvedTextTertiary)
        }
        .buttonStyle(.plain)
        .help("Insert emoji")
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            EmojiPickerView { emoji in
                text.append(emoji)
            }
        }
    }
}
