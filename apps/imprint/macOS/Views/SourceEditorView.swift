import SwiftUI
import AppKit
import ImpressHelixCore
import ImpressKit
import UniformTypeIdentifiers
import ImpressLogging
import OSLog

/// Source code editor with format-aware syntax highlighting and inline AI completions.
/// Supports both Typst and LaTeX syntax.
struct SourceEditorView: View {
    @Binding var source: String
    @Binding var cursorPosition: Int
    var syntaxMode: DocumentFormat = .typst
    var onSelectionChange: ((String, NSRange) -> Void)?

    @AppStorage("imprint.helix.isEnabled") private var helixModeEnabled = false
    @AppStorage("imprint.helix.showModeIndicator") private var helixShowModeIndicator = true

    @State private var helixState = HelixState()
    private let inlineCompletionService = InlineCompletionService.shared

    init(source: Binding<String>, cursorPosition: Binding<Int>, syntaxMode: DocumentFormat = .typst, onSelectionChange: ((String, NSRange) -> Void)? = nil) {
        self._source = source
        self._cursorPosition = cursorPosition
        self.syntaxMode = syntaxMode
        self.onSelectionChange = onSelectionChange
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Color.clear expands to fill available space, forcing ZStack to full size
            Color.clear

            TypstEditorRepresentable(
                source: $source,
                cursorPosition: $cursorPosition,
                syntaxMode: syntaxMode,
                helixState: helixState,
                helixEnabled: helixModeEnabled,
                inlineCompletionService: inlineCompletionService,
                onSelectionChange: onSelectionChange
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
        .onDrop(of: [.impressPaperReference, .impressFigureReference], isTargeted: nil) { providers in
            handleCrossAppDrop(providers)
        }
    }

    /// Handle drops of ImpressPaperRef (from imbib) and ImpressFigureRef (from implore).
    private func handleCrossAppDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.impressPaperReference.identifier) {
                let mode = syntaxMode
                provider.loadDataRepresentation(forTypeIdentifier: UTType.impressPaperReference.identifier) { data, _ in
                    guard let data, let ref = try? JSONDecoder().decode(ImpressPaperRef.self, from: data) else { return }
                    Task { @MainActor in
                        let cite = mode.citationInsert
                        let citation = "\(cite.prefix)\(ref.citeKey)\(cite.suffix)"
                        insertAtCursor(citation)
                        Logger.editor.infoCapture("Inserted citation \(citation) from imbib drop", category: "editor")
                    }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.impressFigureReference.identifier) {
                let mode = syntaxMode
                provider.loadDataRepresentation(forTypeIdentifier: UTType.impressFigureReference.identifier) { data, _ in
                    guard let data, let ref = try? JSONDecoder().decode(ImpressFigureRef.self, from: data) else { return }
                    Task { @MainActor in
                        let title = ref.title ?? "figure"
                        let snippet: String
                        switch mode {
                        case .typst:
                            snippet = "#figure(image(\"figures/\(ref.id.uuidString).\(ref.format ?? "png")\"), caption: [\(title)])"
                        case .latex:
                            snippet = "\\begin{figure}\n  \\includegraphics{figures/\(ref.id.uuidString).\(ref.format ?? "png")}\n  \\caption{\(title)}\n\\end{figure}"
                        }
                        insertAtCursor(snippet)
                        Logger.editor.infoCapture("Inserted figure reference from implore drop", category: "editor")
                    }
                }
                handled = true
            }
        }
        return handled
    }

    private func insertAtCursor(_ text: String) {
        let pos = cursorPosition
        let index = source.index(source.startIndex, offsetBy: min(pos, source.count))
        source.insert(contentsOf: text, at: index)
        cursorPosition = pos + text.count
    }
}

/// NSTextView wrapper for Typst/LaTeX editing with inline AI completions
struct TypstEditorRepresentable: NSViewRepresentable {
    @Binding var source: String
    @Binding var cursorPosition: Int
    let syntaxMode: DocumentFormat
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

        // Set up text container for scrollable editing
        let contentSize = scrollView.contentSize
        textView.frame = NSRect(origin: .zero, size: contentSize)
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

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

        // Ensure text view fills at least the visible area of the scroll view
        let contentSize = scrollView.contentSize
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        if textView.frame.height < contentSize.height {
            textView.setFrameSize(NSSize(width: contentSize.width, height: contentSize.height))
        }

        // Update Helix enabled state
        context.coordinator.helixAdaptor?.isEnabled = helixEnabled

        // Update ghost text
        textView.updateGhostText()

        // Re-highlight if syntax mode changed (e.g. format detected after initial render)
        let modeChanged = context.coordinator.lastSyntaxMode != syntaxMode
        if modeChanged {
            context.coordinator.lastSyntaxMode = syntaxMode
            applySyntaxHighlighting(to: textView)
        }

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
        switch syntaxMode {
        case .typst:
            applyTypstHighlighting(to: textView)
        case .latex:
            applyLaTeXHighlighting(to: textView)
        }
    }

    private func applyTypstHighlighting(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]

        textStorage.beginEditing()
        textStorage.setAttributes(defaultAttributes, range: fullRange)

        let source = textStorage.string

        let keywords = ["let", "set", "show", "import", "include", "if", "else", "for", "while", "return", "break", "continue"]
        for keyword in keywords {
            highlightPattern("\\b\(keyword)\\b", in: source, textStorage: textStorage, color: .systemPurple)
        }

        highlightPattern("^=+\\s.*$", in: source, textStorage: textStorage, color: .systemBlue, options: .anchorsMatchLines)
        highlightPattern("//.*$", in: source, textStorage: textStorage, color: .systemGreen, options: .anchorsMatchLines)
        highlightPattern("@[a-zA-Z0-9_:-]+", in: source, textStorage: textStorage, color: .systemOrange)
        highlightPattern("\"[^\"]*\"", in: source, textStorage: textStorage, color: .systemRed)
        highlightPattern("\\$[^\\$]+\\$", in: source, textStorage: textStorage, color: .systemTeal)
        highlightPattern("#[a-zA-Z_][a-zA-Z0-9_]*", in: source, textStorage: textStorage, color: .systemIndigo)

        textStorage.endEditing()
    }

    private func applyLaTeXHighlighting(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]

        textStorage.beginEditing()
        textStorage.setAttributes(defaultAttributes, range: fullRange)

        let source = textStorage.string

        // Comments: % ...
        highlightPattern("%.*$", in: source, textStorage: textStorage, color: .systemGreen, options: .anchorsMatchLines)

        // Environment begin/end: \begin{...} and \end{...}
        highlightPattern("\\\\(?:begin|end)\\{[^}]+\\}", in: source, textStorage: textStorage, color: .systemBlue)

        // Commands: \commandname
        highlightPattern("\\\\[a-zA-Z@]+", in: source, textStorage: textStorage, color: .systemPurple)

        // Citations, references, labels: \cite{...}, \ref{...}, \label{...}
        highlightPattern("\\\\(?:cite|ref|eqref|pageref|label|autoref|cref|Cref|citep|citet|citealp|textcite|parencite|autocite)\\{[^}]+\\}", in: source, textStorage: textStorage, color: .systemOrange)

        // Math: $...$ and $$...$$
        highlightPattern("\\$\\$[^\\$]+\\$\\$", in: source, textStorage: textStorage, color: .systemTeal)
        highlightPattern("\\$[^\\$]+\\$", in: source, textStorage: textStorage, color: .systemTeal)

        // Strings in arguments: "..."
        highlightPattern("\"[^\"]*\"", in: source, textStorage: textStorage, color: .systemRed)

        textStorage.endEditing()
    }

    /// Apply syntax highlighting only within the given range (plus context for multi-line patterns).
    private func applySyntaxHighlightingRange(to textView: NSTextView, range: NSRange) {
        guard let textStorage = textView.textStorage else { return }

        // Expand range slightly to handle multi-line patterns (e.g. $$...$$)
        let expandedStart = max(0, range.location - 100)
        let expandedEnd = min(textStorage.length, NSMaxRange(range) + 100)
        let expandedRange = NSRange(location: expandedStart, length: expandedEnd - expandedStart)

        let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]

        textStorage.beginEditing()
        textStorage.setAttributes(defaultAttributes, range: expandedRange)

        let source = textStorage.string

        switch syntaxMode {
        case .typst:
            let keywords = ["let", "set", "show", "import", "include", "if", "else", "for", "while", "return", "break", "continue"]
            for keyword in keywords {
                highlightPattern("\\b\(keyword)\\b", in: source, textStorage: textStorage, color: .systemPurple, searchRange: expandedRange)
            }
            highlightPattern("^=+\\s.*$", in: source, textStorage: textStorage, color: .systemBlue, options: .anchorsMatchLines, searchRange: expandedRange)
            highlightPattern("//.*$", in: source, textStorage: textStorage, color: .systemGreen, options: .anchorsMatchLines, searchRange: expandedRange)
            highlightPattern("@[a-zA-Z0-9_:-]+", in: source, textStorage: textStorage, color: .systemOrange, searchRange: expandedRange)
            highlightPattern("\"[^\"]*\"", in: source, textStorage: textStorage, color: .systemRed, searchRange: expandedRange)
            highlightPattern("\\$[^\\$]+\\$", in: source, textStorage: textStorage, color: .systemTeal, searchRange: expandedRange)
            highlightPattern("#[a-zA-Z_][a-zA-Z0-9_]*", in: source, textStorage: textStorage, color: .systemIndigo, searchRange: expandedRange)
        case .latex:
            highlightPattern("%.*$", in: source, textStorage: textStorage, color: .systemGreen, options: .anchorsMatchLines, searchRange: expandedRange)
            highlightPattern("\\\\(?:begin|end)\\{[^}]+\\}", in: source, textStorage: textStorage, color: .systemBlue, searchRange: expandedRange)
            highlightPattern("\\\\[a-zA-Z@]+", in: source, textStorage: textStorage, color: .systemPurple, searchRange: expandedRange)
            highlightPattern("\\\\(?:cite|ref|eqref|pageref|label|autoref|cref|Cref|citep|citet|citealp|textcite|parencite|autocite)\\{[^}]+\\}", in: source, textStorage: textStorage, color: .systemOrange, searchRange: expandedRange)
            highlightPattern("\\$\\$[^\\$]+\\$\\$", in: source, textStorage: textStorage, color: .systemTeal, searchRange: expandedRange)
            highlightPattern("\\$[^\\$]+\\$", in: source, textStorage: textStorage, color: .systemTeal, searchRange: expandedRange)
            highlightPattern("\"[^\"]*\"", in: source, textStorage: textStorage, color: .systemRed, searchRange: expandedRange)
        }

        textStorage.endEditing()
    }

    private func highlightPattern(_ pattern: String, in source: String, textStorage: NSTextStorage, color: NSColor, options: NSRegularExpression.Options = [], searchRange: NSRange? = nil) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }

        let range = searchRange ?? NSRange(source.startIndex..., in: source)
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
        /// Tracks the last syntax mode to detect format changes (e.g. .typst → .latex after file load)
        var lastSyntaxMode: DocumentFormat = .typst
        private var completionDebounceTask: Task<Void, Never>?
        private var latexCompletionTask: Task<Void, Never>?
        private var cachedLaTeXCompletions: [String] = []

        init(_ parent: TypstEditorRepresentable) {
            self.parent = parent
            self.lastSyntaxMode = parent.syntaxMode
        }

        // MARK: - LaTeX Completion Support

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard parent.syntaxMode == .latex else { return [] }

            let source = textView.string
            let cursorOffset = textView.selectedRange().location

            // Extract the prefix leading up to cursor for context
            let startIndex = source.startIndex
            let prefixEnd = source.index(startIndex, offsetBy: min(cursorOffset, source.count))
            // Look back up to 50 chars for context
            let lookback = min(cursorOffset, 50)
            let prefixStart = source.index(prefixEnd, offsetBy: -lookback)
            let prefix = String(source[prefixStart..<prefixEnd])

            // Return cached results immediately
            let currentResults = cachedLaTeXCompletions

            // Fetch fresh completions asynchronously for next invocation
            let capturedPrefix = prefix
            let capturedSource = source
            let capturedOffset = cursorOffset
            let capturedTextView = textView
            latexCompletionTask?.cancel()
            latexCompletionTask = Task { @MainActor [weak self] in
                let completions = await LaTeXCompletionProvider.shared.completions(
                    for: capturedPrefix,
                    in: capturedSource,
                    at: capturedOffset
                )
                self?.cachedLaTeXCompletions = completions.map(\.text)
                // Re-trigger completion if results changed
                if self?.cachedLaTeXCompletions != currentResults {
                    capturedTextView.complete(nil)
                }
            }

            return currentResults
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.source = textView.string

            // Update cursor position
            let selectedRange = textView.selectedRange()
            parent.cursorPosition = selectedRange.location

            // Highlight only the changed paragraph (not full document)
            if let textStorage = textView.textStorage, textStorage.editedRange.location != NSNotFound {
                let paragraphRange = (textStorage.string as NSString).paragraphRange(for: textStorage.editedRange)
                parent.applySyntaxHighlightingRange(to: textView, range: paragraphRange)
            } else {
                parent.applySyntaxHighlighting(to: textView)
            }

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
                Logger.editor.infoCapture("Accepted inline completion via Tab", category: "editor")
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
