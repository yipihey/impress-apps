import SwiftUI
import AppKit
import ImpressHelixCore

/// Typst source code editor with syntax highlighting
struct SourceEditorView: View {
    @Binding var source: String
    @Binding var cursorPosition: Int
    var onSelectionChange: ((String, NSRange) -> Void)?

    @AppStorage("imprint.helix.isEnabled") private var helixModeEnabled = false
    @AppStorage("imprint.helix.showModeIndicator") private var helixShowModeIndicator = true

    @StateObject private var helixState = HelixState()

    init(source: Binding<String>, cursorPosition: Binding<Int>, onSelectionChange: ((String, NSRange) -> Void)? = nil) {
        self._source = source
        self._cursorPosition = cursorPosition
        self.onSelectionChange = onSelectionChange
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Color.clear expands to fill available space, forcing ZStack to full size
            Color.clear

            TypstEditorRepresentable(
                source: $source,
                cursorPosition: $cursorPosition,
                helixState: helixState,
                helixEnabled: helixModeEnabled,
                onSelectionChange: onSelectionChange
            )

            if helixModeEnabled && helixShowModeIndicator {
                HelixModeIndicator(state: helixState, position: .bottomLeft)
                    .padding(12)
            }
        }
        .accessibilityIdentifier("sourceEditor.container")
    }
}

/// NSTextView wrapper for Typst editing
struct TypstEditorRepresentable: NSViewRepresentable {
    @Binding var source: String
    @Binding var cursorPosition: Int
    let helixState: HelixState
    let helixEnabled: Bool
    var onSelectionChange: ((String, NSRange) -> Void)?

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

        // Set up Helix adaptor
        let adaptor = NSTextViewHelixAdaptor(textView: textView, helixState: helixState)
        adaptor.isEnabled = helixEnabled
        textView.helixAdaptor = adaptor
        context.coordinator.helixAdaptor = adaptor

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Set initial text
        textView.string = source
        applySyntaxHighlighting(to: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TypstTextView else { return }

        // Update Helix enabled state
        context.coordinator.helixAdaptor?.isEnabled = helixEnabled

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
        var helixAdaptor: NSTextViewHelixAdaptor?

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
            let selectedRange = textView.selectedRange()
            parent.cursorPosition = selectedRange.location

            // Notify parent of selected text and range
            if selectedRange.length > 0,
               let textStorage = textView.textStorage {
                let selectedText = textStorage.string.substring(with: selectedRange)
                parent.onSelectionChange?(selectedText, selectedRange)
            } else {
                parent.onSelectionChange?("", selectedRange)
            }

            // Update collaboration cursor
            textView.updateCollaborationCursor()
        }
    }
}

// MARK: - String Extension

extension String {
    func substring(with nsRange: NSRange) -> String {
        guard let range = Range(nsRange, in: self) else { return "" }
        return String(self[range])
    }
}

/// Custom NSTextView subclass for Typst editing with Helix support
class TypstTextView: HelixTextView {
    // Line numbers could be added here
    // Auto-completion could be added here
}

#Preview {
    SourceEditorView(
        source: .constant("= Hello World\n\nThis is a test document."),
        cursorPosition: .constant(0),
        onSelectionChange: { _, _ in }
    )
    .frame(width: 500, height: 400)
}
