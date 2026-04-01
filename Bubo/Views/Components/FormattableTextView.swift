import SwiftUI
import AppKit

/// A multi-line text view that adds Markdown formatting items to the
/// Transformations submenu of the standard context menu.
///
/// The placeholder is rendered as a SwiftUI `Text` overlay so it matches
/// the native `TextField` prompt styling exactly.
struct FormattableTextView: View {
    @Binding var text: String
    var prompt: String = ""
    var promptStyle: Color = Color(nsColor: .placeholderTextColor)

    var body: some View {
        ZStack(alignment: .topLeading) {
            FormattableTextViewRepresentable(text: $text)

            if text.isEmpty && !prompt.isEmpty {
                Text(prompt)
                    .foregroundStyle(promptStyle)
                    .padding(.leading, 5)
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - NSViewRepresentable bridge

private struct FormattableTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = FormattableNSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? FormattableNSTextView else { return }
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FormattableTextViewRepresentable

        init(_ parent: FormattableTextViewRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

// MARK: - Custom NSTextView with extended Transformations menu

final class FormattableNSTextView: NSTextView {
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }

        // Find the existing Transformations submenu
        if let transformItem = menu.items.first(where: { $0.submenu?.title == "Transformations" }),
           let submenu = transformItem.submenu {
            submenu.addItem(.separator())
            addMarkdownItems(to: submenu)
        } else {
            // Create Transformations submenu if it doesn't exist
            let submenu = NSMenu(title: "Transformations")

            // Standard text transformations
            let upper = NSMenuItem(title: "Make Upper Case", action: #selector(NSStandardKeyBindingResponding.uppercaseWord(_:)), keyEquivalent: "")
            let lower = NSMenuItem(title: "Make Lower Case", action: #selector(NSStandardKeyBindingResponding.lowercaseWord(_:)), keyEquivalent: "")
            let capitalize = NSMenuItem(title: "Capitalize", action: #selector(NSStandardKeyBindingResponding.capitalizeWord(_:)), keyEquivalent: "")
            submenu.addItem(upper)
            submenu.addItem(lower)
            submenu.addItem(capitalize)

            submenu.addItem(.separator())
            addMarkdownItems(to: submenu)

            let transformItem = NSMenuItem(title: "Transformations", action: nil, keyEquivalent: "")
            transformItem.submenu = submenu
            menu.addItem(transformItem)
        }

        return menu
    }

    private func addMarkdownItems(to menu: NSMenu) {
        let items: [(String, Selector, String)] = [
            ("Bold", #selector(wrapBold(_:)), "b"),
            ("Italic", #selector(wrapItalic(_:)), "i"),
            ("Strikethrough", #selector(wrapStrikethrough(_:)), ""),
            ("Code", #selector(wrapCode(_:)), ""),
            ("Quote", #selector(wrapQuote(_:)), ""),
            ("Make Link", #selector(wrapLink(_:)), ""),
        ]

        for (title, action, key) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if !key.isEmpty {
                item.keyEquivalentModifierMask = [.command]
            }
            item.target = self
            menu.addItem(item)
        }
    }

    // MARK: - Markdown wrapping actions

    @objc private func wrapBold(_ sender: Any?) {
        wrapSelection(prefix: "**", suffix: "**")
    }

    @objc private func wrapItalic(_ sender: Any?) {
        wrapSelection(prefix: "*", suffix: "*")
    }

    @objc private func wrapStrikethrough(_ sender: Any?) {
        wrapSelection(prefix: "~~", suffix: "~~")
    }

    @objc private func wrapCode(_ sender: Any?) {
        wrapSelection(prefix: "`", suffix: "`")
    }

    @objc private func wrapQuote(_ sender: Any?) {
        guard let range = selectedRanges.first?.rangeValue,
              range.length > 0 else { return }
        let selected = (string as NSString).substring(with: range)
        let quoted = selected
            .components(separatedBy: "\n")
            .map { "> \($0)" }
            .joined(separator: "\n")
        insertText(quoted, replacementRange: range)
    }

    @objc private func wrapLink(_ sender: Any?) {
        guard let range = selectedRanges.first?.rangeValue else { return }
        let selected = range.length > 0
            ? (string as NSString).substring(with: range)
            : "link"
        let replacement = "[\(selected)](url)"
        insertText(replacement, replacementRange: range)
        // Select "url" so user can type the actual URL
        let urlStart = range.location + selected.count + 3 // after "[text]("
        setSelectedRange(NSRange(location: urlStart, length: 3))
    }

    private func wrapSelection(prefix: String, suffix: String) {
        guard let range = selectedRanges.first?.rangeValue else { return }
        let selected = range.length > 0
            ? (string as NSString).substring(with: range)
            : ""

        // If already wrapped, unwrap
        if selected.hasPrefix(prefix) && selected.hasSuffix(suffix) && selected.count >= prefix.count + suffix.count {
            let unwrapped = String(selected.dropFirst(prefix.count).dropLast(suffix.count))
            insertText(unwrapped, replacementRange: range)
            setSelectedRange(NSRange(location: range.location, length: unwrapped.count))
            return
        }

        let replacement = "\(prefix)\(selected)\(suffix)"
        insertText(replacement, replacementRange: range)
        if selected.isEmpty {
            // Place cursor between the markers
            setSelectedRange(NSRange(location: range.location + prefix.count, length: 0))
        } else {
            setSelectedRange(NSRange(location: range.location, length: replacement.count))
        }
    }
}
