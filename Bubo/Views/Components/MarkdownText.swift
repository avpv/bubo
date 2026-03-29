import SwiftUI

/// Renders a string as Markdown using `AttributedString`.
/// Falls back to plain text if parsing fails.
struct MarkdownText: View {
    let text: String

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    var body: some View {
        Text(attributed)
    }
}
