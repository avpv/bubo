import SwiftUI

/// Renders a Markdown string with block-level elements:
/// headings, paragraphs, lists, code blocks, blockquotes, horizontal rules, and tables.
/// Inline formatting (bold, italic, code, links, strikethrough) is supported within all text blocks.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: - Block model

    private enum Block {
        case heading(String, level: Int)
        case paragraph(String)
        case unorderedItem(String, depth: Int)
        case orderedItem(Int, String, depth: Int)
        case codeBlock(String, language: String?)
        case blockquote(String)
        case horizontalRule
        case taskItem(String, checked: Bool, depth: Int)
        case table(header: [String], alignments: [TableAlignment], rows: [[String]])
    }

    private enum TableAlignment {
        case left, center, right
    }

    // MARK: - Block views

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let content, let level):
            headingView(content, level: level)

        case .paragraph(let content):
            Text(inlineMarkdown(content))
                .lineSpacing(DS.Typography.bodyLineSpacing)

        case .unorderedItem(let content, let depth):
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                Text(depth == 0 ? "•" : "◦")
                    .foregroundStyle(.tertiary)
                Text(inlineMarkdown(content))
                    .lineSpacing(DS.Typography.bodyLineSpacing)
            }
            .padding(.leading, CGFloat(depth) * DS.Spacing.lg)

        case .orderedItem(let index, let content, let depth):
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                Text("\(index).")
                    .foregroundStyle(.tertiary)
                Text(inlineMarkdown(content))
                    .lineSpacing(DS.Typography.bodyLineSpacing)
            }
            .padding(.leading, CGFloat(depth) * DS.Spacing.lg)

        case .taskItem(let content, let checked, let depth):
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: DS.Size.iconMedium))
                    .foregroundStyle(checked ? DS.Colors.accent : DS.Colors.textTertiary)
                Text(inlineMarkdown(content))
                    .lineSpacing(DS.Typography.bodyLineSpacing)
                    .strikethrough(checked, color: DS.Colors.textTertiary)
                    .foregroundStyle(checked ? DS.Colors.textTertiary : DS.Colors.textSecondary)
            }
            .padding(.leading, CGFloat(depth) * DS.Spacing.lg)

        case .codeBlock(let code, _):
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .padding(DS.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.hoverFill)
                .clipShape(RoundedRectangle(cornerRadius: DS.Spacing.sm, style: .continuous))

        case .blockquote(let content):
            HStack(spacing: DS.Spacing.sm) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(DS.Colors.accent.opacity(0.5))
                    .frame(width: DS.Spacing.xxs)
                Text(inlineMarkdown(content))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineSpacing(DS.Typography.bodyLineSpacing)
            }

        case .horizontalRule:
            Divider()
                .padding(.vertical, DS.Spacing.xs)

        case .table(let header, let alignments, let rows):
            tableView(header: header, alignments: alignments, rows: rows)
        }
    }

    // MARK: - Heading

    @ViewBuilder
    private func headingView(_ content: String, level: Int) -> some View {
        switch level {
        case 1:
            Text(inlineMarkdown(content))
                .font(.system(.title2, design: .rounded, weight: .bold))
        case 2:
            Text(inlineMarkdown(content))
                .font(.system(.title3, design: .rounded, weight: .semibold))
        case 3:
            Text(inlineMarkdown(content))
                .font(.system(.headline, design: .rounded, weight: .semibold))
        default:
            Text(inlineMarkdown(content))
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
        }
    }

    // MARK: - Table

    @ViewBuilder
    private func tableView(header: [String], alignments: [TableAlignment], rows: [[String]]) -> some View {
        let columnCount = header.count

        Grid(alignment: .leading, horizontalSpacing: DS.Spacing.md, verticalSpacing: DS.Spacing.xs) {
            // Header row
            GridRow {
                ForEach(0..<columnCount, id: \.self) { col in
                    Text(inlineMarkdown(header[col]))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: gridAlignment(alignments, col))
                }
            }

            Divider()

            // Data rows
            ForEach(0..<rows.count, id: \.self) { rowIdx in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { col in
                        let cell = col < rows[rowIdx].count ? rows[rowIdx][col] : ""
                        Text(inlineMarkdown(cell))
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: gridAlignment(alignments, col))
                    }
                }
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.hoverFill)
        .clipShape(RoundedRectangle(cornerRadius: DS.Spacing.sm, style: .continuous))
    }

    private func gridAlignment(_ alignments: [TableAlignment], _ col: Int) -> Alignment {
        guard col < alignments.count else { return .leading }
        switch alignments[col] {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    // MARK: - Block parsing

    private var blocks: [Block] {
        let lines = text.components(separatedBy: "\n")
        var result: [Block] = []
        var paragraphLines: [String] = []
        var i = 0

        func flushParagraph() {
            let joined = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                result.append(.paragraph(joined))
            }
            paragraphLines.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line — flush paragraph
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Fenced code block (``` or ~~~)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                result.append(.codeBlock(codeLines.joined(separator: "\n"), language: lang.isEmpty ? nil : lang))
                continue
            }

            // Horizontal rule (---, ***, ___ with optional spaces)
            if isHorizontalRule(trimmed) {
                flushParagraph()
                result.append(.horizontalRule)
                i += 1
                continue
            }

            // Heading (# ... up to ######)
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                result.append(heading)
                i += 1
                continue
            }

            // Table: check if current + next line form a table header + separator
            if let table = parseTable(lines: lines, from: i) {
                flushParagraph()
                result.append(table.block)
                i = table.nextIndex
                continue
            }

            // Blockquote (> ...)
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while i < lines.count {
                    let ql = lines[i].trimmingCharacters(in: .whitespaces)
                    guard ql.hasPrefix(">") else { break }
                    var content = String(ql.dropFirst())
                    if content.hasPrefix(" ") { content = String(content.dropFirst()) }
                    quoteLines.append(content)
                    i += 1
                }
                result.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            // List item
            if let item = parseListItem(line) {
                flushParagraph()
                result.append(item)
                i += 1
                continue
            }

            // Regular paragraph line
            paragraphLines.append(line)
            i += 1
        }

        flushParagraph()
        return result
    }

    // MARK: - Line-level parsers

    private func parseHeading(_ trimmed: String) -> Block? {
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1 && level <= 6 else { return nil }
        guard trimmed.count > level else { return .heading("", level: level) }
        let afterHashes = trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)...]
        guard afterHashes.first == " " else { return nil }
        let content = String(afterHashes.dropFirst()).trimmingCharacters(in: .whitespaces)
        return .heading(content, level: level)
    }

    private func isHorizontalRule(_ trimmed: String) -> Bool {
        let cleaned = trimmed.replacingOccurrences(of: " ", with: "")
        guard cleaned.count >= 3 else { return false }
        let chars = Set(cleaned)
        return chars.count == 1 && (chars.contains("-") || chars.contains("*") || chars.contains("_"))
    }

    private func parseListItem(_ line: String) -> Block? {
        let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
        let indent = line.count - stripped.count
        let depth = indent / 2

        let trimmed = String(stripped)

        // Task list: - [ ] unchecked, - [x] checked (also with * or +)
        for prefix in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(prefix) {
                let afterPrefix = String(trimmed.dropFirst(prefix.count))
                if afterPrefix.hasPrefix("[ ] ") {
                    return .taskItem(String(afterPrefix.dropFirst(4)), checked: false, depth: depth)
                }
                if afterPrefix.hasPrefix("[x] ") || afterPrefix.hasPrefix("[X] ") {
                    return .taskItem(String(afterPrefix.dropFirst(4)), checked: true, depth: depth)
                }
            }
        }

        // Unordered: - item, * item, + item
        // Avoid matching horizontal rules like "---" or "***"
        for prefix in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(prefix) {
                let content = String(trimmed.dropFirst(prefix.count))
                return .unorderedItem(content, depth: depth)
            }
        }

        // Ordered: 1. item
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

    // MARK: - Table parser

    private struct TableParseResult {
        let block: Block
        let nextIndex: Int
    }

    private func parseTable(lines: [String], from start: Int) -> TableParseResult? {
        guard start + 1 < lines.count else { return nil }

        let headerLine = lines[start].trimmingCharacters(in: .whitespaces)
        let separatorLine = lines[start + 1].trimmingCharacters(in: .whitespaces)

        guard headerLine.contains("|") && separatorLine.contains("|") else { return nil }

        let headerCells = parseTableRow(headerLine)
        let sepCells = parseTableRow(separatorLine)

        // Validate separator: each cell must match /^:?-+:?$/
        guard headerCells.count == sepCells.count else { return nil }
        var alignments: [TableAlignment] = []
        for cell in sepCells {
            let s = cell.trimmingCharacters(in: .whitespaces)
            let stripped = s.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
            guard stripped.isEmpty && s.contains("-") else { return nil }

            let left = s.hasPrefix(":")
            let right = s.hasSuffix(":")
            if left && right { alignments.append(.center) }
            else if right { alignments.append(.right) }
            else { alignments.append(.left) }
        }

        // Parse data rows
        var rows: [[String]] = []
        var i = start + 2
        while i < lines.count {
            let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
            guard rowLine.contains("|") else { break }
            rows.append(parseTableRow(rowLine))
            i += 1
        }

        return TableParseResult(
            block: .table(header: headerCells, alignments: alignments, rows: rows),
            nextIndex: i
        )
    }

    private func parseTableRow(_ line: String) -> [String] {
        var row = line
        // Strip leading/trailing pipes
        if row.hasPrefix("|") { row = String(row.dropFirst()) }
        if row.hasSuffix("|") { row = String(row.dropLast()) }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Inline markdown

    private func inlineMarkdown(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
    }
}
