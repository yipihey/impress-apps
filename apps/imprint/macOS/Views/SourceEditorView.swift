import SwiftUI
import AppKit

/// Typst source code editor with syntax highlighting
struct SourceEditorView: View {
    @Binding var source: String
    @Binding var cursorPosition: Int

    var body: some View {
        TypstEditorRepresentable(
            source: $source,
            cursorPosition: $cursorPosition
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("sourceEditor.container")
    }
}

/// NSTextView wrapper for Typst editing
struct TypstEditorRepresentable: NSViewRepresentable {
    @Binding var source: String
    @Binding var cursorPosition: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = TypstTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // Configure for code editing
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        // Accessibility
        textView.setAccessibilityIdentifier("sourceEditor.textView")

        // Set up text container
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Set initial text
        textView.string = source
        applySyntaxHighlighting(to: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TypstTextView else { return }

        // Update text if changed externally
        if textView.string != source {
            let selectedRange = textView.selectedRange()
            textView.string = source
            applySyntaxHighlighting(to: textView)

            // Restore selection
            if selectedRange.location <= source.count {
                textView.setSelectedRange(selectedRange)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func applySyntaxHighlighting(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]

        textStorage.beginEditing()
        textStorage.setAttributes(defaultAttributes, range: fullRange)

        let source = textStorage.string

        // Highlight Typst keywords
        let keywords = ["let", "set", "show", "import", "include", "if", "else", "for", "while", "return", "break", "continue"]
        for keyword in keywords {
            highlightPattern("\\b\(keyword)\\b", in: source, textStorage: textStorage, color: .systemPurple)
        }

        // Highlight headings (= Heading)
        highlightPattern("^=+\\s.*$", in: source, textStorage: textStorage, color: .systemBlue, options: .anchorsMatchLines)

        // Highlight comments (// ...)
        highlightPattern("//.*$", in: source, textStorage: textStorage, color: .systemGreen, options: .anchorsMatchLines)

        // Highlight citations (@citeKey)
        highlightPattern("@[a-zA-Z0-9_:-]+", in: source, textStorage: textStorage, color: .systemOrange)

        // Highlight strings ("...")
        highlightPattern("\"[^\"]*\"", in: source, textStorage: textStorage, color: .systemRed)

        // Highlight math ($...$)
        highlightPattern("\\$[^\\$]+\\$", in: source, textStorage: textStorage, color: .systemTeal)

        // Highlight functions (#func())
        highlightPattern("#[a-zA-Z_][a-zA-Z0-9_]*", in: source, textStorage: textStorage, color: .systemIndigo)

        textStorage.endEditing()
    }

    private func highlightPattern(_ pattern: String, in source: String, textStorage: NSTextStorage, color: NSColor, options: NSRegularExpression.Options = []) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }

        let range = NSRange(source.startIndex..., in: source)
        regex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            if let matchRange = match?.range {
                textStorage.addAttribute(.foregroundColor, value: color, range: matchRange)
            }
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TypstEditorRepresentable
        weak var textView: NSTextView?

        init(_ parent: TypstEditorRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.source = textView.string

            // Update cursor position
            let selectedRange = textView.selectedRange()
            parent.cursorPosition = selectedRange.location

            // Re-apply syntax highlighting
            parent.applySyntaxHighlighting(to: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.cursorPosition = textView.selectedRange().location
        }
    }
}

/// Custom NSTextView subclass for Typst editing
class TypstTextView: NSTextView {
    // Line numbers could be added here
    // Auto-completion could be added here
}

#Preview {
    SourceEditorView(
        source: .constant("= Hello World\n\nThis is a test document."),
        cursorPosition: .constant(0)
    )
    .frame(width: 500, height: 400)
}
