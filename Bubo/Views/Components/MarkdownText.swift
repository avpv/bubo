import SwiftUI

/// Renders a string as Markdown, including block-level lists.
/// Falls back to plain text if parsing fails.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let content):
                    Text(inlineMarkdown(content))
                case .unorderedItem(let content, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                        Text(depth == 0 ? "•" : "◦")
                            .foregroundStyle(.tertiary)
                        Text(inlineMarkdown(content))
                    }
                    .padding(.leading, CGFloat(depth) * DS.Spacing.lg)
                case .orderedItem(let index, let content, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                        Text("\(index).")
                            .foregroundStyle(.tertiary)
                        Text(inlineMarkdown(content))
                    }
                    .padding(.leading, CGFloat(depth) * DS.Spacing.lg)
                }
            }
        }
    }

    // MARK: - Block parsing

    private enum Block {
        case paragraph(String)
        case unorderedItem(String, depth: Int)
        case orderedItem(Int, String, depth: Int)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            let joined = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                result.append(.paragraph(joined))
            }
            paragraphLines.removeAll()
        }

        for line in text.components(separatedBy: .newlines) {
            if let item = parseListItem(line) {
                flushParagraph()
                result.append(item)
            } else {
                paragraphLines.append(line)
            }
        }
        flushParagraph()
        return result
    }

    private func parseListItem(_ line: String) -> Block? {
        // Count leading whitespace for nesting depth
        let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
        let indent = line.count - stripped.count
        let depth = indent / 2  // 2-space indent per level

        let trimmed = String(stripped)

        // Unordered: - item, * item, + item
        for prefix in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(prefix) {
                let content = String(trimmed.dropFirst(prefix.count))
                return .unorderedItem(content, depth: depth)
            }
        }

        // Ordered: 1. item, 2. item, etc.
        if let dotIndex = trimmed.firstIndex(of: "."),
           dotIndex != trimmed.startIndex,
           let num = Int(trimmed[trimmed.startIndex..<dotIndex]) {
            let afterDot = trimmed.index(after: dotIndex)
            if afterDot < trimmed.endIndex && trimmed[afterDot] == " " {
                let content = String(trimmed[trimmed.index(after: afterDot)...])
                return .orderedItem(num, content, depth: depth)
            }
        }

        return nil
    }

    // MARK: - Inline markdown

    private func inlineMarkdown(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
    }
}
