import SwiftUI
import AppKit
import ImpressHelixCore
import OSLog

private let logger = Logger(subsystem: "com.imprint.app", category: "sourceEditor")

/// Typst source code editor with syntax highlighting and inline AI completions
struct SourceEditorView: View {
    @Binding var source: String
    @Binding var cursorPosition: Int
    var onSelectionChange: ((String, NSRange) -> Void)?

    @AppStorage("imprint.helix.isEnabled") private var helixModeEnabled = false
    @AppStorage("imprint.helix.showModeIndicator") private var helixShowModeIndicator = true

    @State private var helixState = HelixState()
    private let inlineCompletionService = InlineCompletionService.shared

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
                inlineCompletionService: inlineCompletionService,
                onSelectionChange: onSelectionChange
            )

            // Helix mode indicator
            if helixModeEnabled && helixShowModeIndicator {
                HelixModeIndicator(state: helixState, position: .bottomLeft)
                    .padding(12)
            }

            // Inline completion loading indicator
            if inlineCompletionService.isLoading {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("AI")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding([.trailing, .bottom], 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .accessibilityIdentifier("sourceEditor.container")
    }
}

/// NSTextView wrapper for Typst editing with inline AI completions
struct TypstEditorRepresentable: NSViewRepresentable {
    @Binding var source: String
    @Binding var cursorPosition: Int
    let helixState: HelixState
    let helixEnabled: Bool
    let inlineCompletionService: InlineCompletionService
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

        // Set up inline completion service
        textView.inlineCompletionService = inlineCompletionService

        // Add ghost text overlay
        let ghostTextView = GhostTextNSView(frame: .zero)
        ghostTextView.textFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.addSubview(ghostTextView)
        textView.ghostTextView = ghostTextView

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

        // Update ghost text
        textView.updateGhostText()

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
        private var completionDebounceTask: Task<Void, Never>?

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

            // Request inline completion
            requestInlineCompletion(text: textView.string, position: selectedRange.location)
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

            // Clear completion on selection change
            if selectedRange.length > 0 {
                parent.inlineCompletionService.clearCompletion()
            }

            // Update ghost text position
            if let typstTextView = textView as? TypstTextView {
                typstTextView.updateGhostText()
            }

            // Update collaboration cursor
            textView.updateCollaborationCursor()
        }

        private func requestInlineCompletion(text: String, position: Int) {
            // Capture service reference for Task
            let service = parent.inlineCompletionService
            let capturedText = text
            let capturedPosition = position

            Task { @MainActor in
                service.requestCompletion(text: capturedText, cursorPosition: capturedPosition)
            }
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

/// Custom NSTextView subclass for Typst editing with Helix support and inline completions
class TypstTextView: HelixTextView {

    // MARK: - Inline Completion Properties

    /// Service for inline AI completions
    var inlineCompletionService: InlineCompletionService?

    /// Ghost text overlay view
    var ghostTextView: GhostTextNSView?

    // MARK: - Key Handling

    override func keyDown(with event: NSEvent) {
        // Tab key accepts inline completion if available
        if event.keyCode == 48 { // Tab key
            if let service = inlineCompletionService,
               let accepted = service.acceptCompletion() {
                // Insert the accepted text at cursor
                insertText(accepted, replacementRange: selectedRange())
                logger.info("Accepted inline completion via Tab")
                return
            }
        }

        // Escape clears completion
        if event.keyCode == 53 { // Escape key
            inlineCompletionService?.clearCompletion()
            updateGhostText()
        }

        // Let Helix handle it, or fall through to normal handling
        super.keyDown(with: event)

        // Update ghost text after any key press
        updateGhostText()
    }

    // MARK: - Ghost Text Management

    /// Update the ghost text display based on current completion.
    func updateGhostText() {
        guard let ghostView = ghostTextView,
              let service = inlineCompletionService else {
            return
        }

        let ghostText = service.ghostText

        if ghostText.isEmpty {
            ghostView.ghostText = ""
            return
        }

        // Position ghost text at cursor
        let cursorPoint = endOfCurrentLinePoint()
        ghostView.cursorPosition = cursorPoint
        ghostView.ghostText = ghostText

        // Update line height from font
        if let font = self.font {
            ghostView.lineHeight = font.ascender - font.descender + font.leading
        }
    }
}

#Preview {
    SourceEditorView(
        source: .constant("= Hello World\n\nThis is a test document."),
        cursorPosition: .constant(0),
        onSelectionChange: { _, _ in }
    )
    .frame(width: 500, height: 400)
}
