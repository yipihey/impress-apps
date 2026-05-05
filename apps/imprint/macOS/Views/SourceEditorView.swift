import SwiftUI
import AppKit
import ImpressHelixCore
import ImpressKit
import ImpressSyntaxHighlight
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

        // Enable standard macOS find bar (Cmd+F, Cmd+G, Cmd+Option+F for replace)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

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

        // Hover preview for cite keys
        textView.hoverController = context.coordinator.hoverController
        textView.currentFormat = syntaxMode

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
        // Keep hover preview's language in sync with current format
        textView.currentFormat = syntaxMode
        if textView.hoverController == nil {
            textView.hoverController = context.coordinator.hoverController
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

        // Handle programmatic cursor navigation (e.g., outline click)
        let requestedPosition = cursorPosition
        if requestedPosition != context.coordinator.lastReportedCursorPosition,
           requestedPosition >= 0,
           requestedPosition <= textView.string.count {
            context.coordinator.lastReportedCursorPosition = requestedPosition
            let range = NSRange(location: requestedPosition, length: 0)
            textView.setSelectedRange(range)
            // Scroll to place the target line at the top of the visible area
            if let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                let targetY = lineRect.origin.y
                let visibleHeight = scrollView.contentView.bounds.height
                let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - visibleHeight)
                let clampedY = min(max(0, targetY), maxY)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else {
                textView.scrollRangeToVisible(range)
            }
            // Make the text view first responder so the cursor blinks
            textView.window?.makeFirstResponder(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Syntax Highlighting (tree-sitter via ImpressSyntaxHighlight)

    /// Get or create a SyntaxHighlighter for the current syntax mode from the coordinator.
    private func syntaxHighlighter(for coordinator: Coordinator) -> SyntaxHighlighter {
        let wantedLanguage: ImpressLanguage = (syntaxMode == .latex) ? .latex : .typst
        if let existing = coordinator.syntaxHighlighter, existing.language == wantedLanguage {
            return existing
        }
        let highlighter = SyntaxHighlighter(language: wantedLanguage)
        coordinator.syntaxHighlighter = highlighter
        return highlighter
    }

    private func applySyntaxHighlighting(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        guard let coordinator = textView.delegate as? Coordinator else { return }

        let highlighter = syntaxHighlighter(for: coordinator)
        // Preserve cursor/selection across the attribute replacement
        let selectedRange = textView.selectedRange()
        highlighter.highlight(textStorage: textStorage, source: textStorage.string)
        // Re-apply the monospaced font (highlighter only touches foreground color)
        textStorage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), range: NSRange(location: 0, length: textStorage.length))
        if selectedRange.location <= textStorage.length {
            textView.setSelectedRange(selectedRange)
        }
    }

    /// Apply syntax highlighting only within the changed paragraph for performance.
    /// Uses tree-sitter's incremental parsing for sub-millisecond re-parse.
    private func applySyntaxHighlightingRange(to textView: NSTextView, range: NSRange) {
        // Tree-sitter re-parses only affected subtrees; full highlight is cheap.
        applySyntaxHighlighting(to: textView)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TypstEditorRepresentable
        weak var textView: NSTextView?
        var helixAdaptor: NSTextViewHelixAdaptor?
        /// Tracks the last syntax mode to detect format changes (e.g. .typst → .latex after file load)
        var lastSyntaxMode: DocumentFormat = .typst
        /// Per-document tree-sitter highlighter (holds parser + tree for incremental parsing)
        var syntaxHighlighter: SyntaxHighlighter?
        /// Inline citation palette controller — shared across edits in this editor.
        /// Lazily created on first main-actor access to avoid init() isolation warnings.
        private var _citationPalette: CitationPaletteController?
        @MainActor
        var citationPalette: CitationPaletteController {
            if let existing = _citationPalette { return existing }
            let c = CitationPaletteController()
            _citationPalette = c
            return c
        }
        /// Hover preview controller for cite keys — lazy-created for the same reason.
        private var _hoverController: CiteKeyHoverController?
        @MainActor
        var hoverController: CiteKeyHoverController {
            if let existing = _hoverController { return existing }
            let c = CiteKeyHoverController()
            _hoverController = c
            return c
        }
        private var completionDebounceTask: Task<Void, Never>?
        private var latexCompletionTask: Task<Void, Never>?
        private var cachedLaTeXCompletions: [String] = []

        /// Tracks cursor position set by the coordinator itself, so updateNSView
        /// can distinguish programmatic navigation from user edits.
        var lastReportedCursorPosition: Int = 0

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
            lastReportedCursorPosition = selectedRange.location
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

            // Inline citation palette: show when the caret is inside `\cite{...}` or after `@`
            maybeShowCitationPalette(in: textView, at: selectedRange.location)
        }

        /// Detects if the current caret position is inside a citation trigger and
        /// shows/hides the inline palette accordingly. Runs on MainActor because
        /// BibliographyGenerator and AppKit views are main-isolated.
        @MainActor
        private func maybeShowCitationPalette(in textView: NSTextView, at cursorLocation: Int) {
            let format = parent.syntaxMode
            if let trigger = CitationPaletteTriggerDetector.detect(
                in: textView.string,
                at: cursorLocation,
                format: format
            ) {
                logInfo("CitationPalette: trigger at loc=\(cursorLocation), query='\(trigger.initialQuery)', format=\(format)", category: "citation-palette")
                let citedKeys = Set(BibliographyGenerator.shared.extractedCiteKeys)
                citationPalette.show(
                    in: textView,
                    at: trigger.insertionRange,
                    initialQuery: trigger.initialQuery,
                    alreadyCitedKeys: citedKeys,
                    format: format
                )
            } else if citationPalette.isShowing {
                logInfo("CitationPalette: dismissing — no trigger at loc=\(cursorLocation)", category: "citation-palette")
                citationPalette.dismiss()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let selectedRange = textView.selectedRange()
            lastReportedCursorPosition = selectedRange.location
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
// MARK: - Typst text view

class TypstTextView: HelixTextView {

    // MARK: - Inline Completion Properties

    /// Service for inline AI completions
    var inlineCompletionService: InlineCompletionService?

    /// Ghost text overlay view
    var ghostTextView: GhostTextNSView?

    // MARK: - Hover Preview

    /// Hover preview popover controller for cite keys.
    var hoverController: CiteKeyHoverController?
    /// Current document format (set by the coordinator) — used to pick the right cite-key parser.
    var currentFormat: DocumentFormat = .typst
    /// Tracking area for mouse-moved events.
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        handleHover(event: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverController?.dismiss()
    }

    private func handleHover(event: NSEvent) {
        let pointInView = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: pointInView)
        guard charIndex != NSNotFound, charIndex >= 0, charIndex < string.count else {
            hoverController?.dismiss()
            return
        }
        if let match = CiteKeyAtLocation.find(in: string, at: charIndex, format: currentFormat) {
            hoverController?.show(in: self, citeKey: match.key, range: match.range)
        } else {
            hoverController?.dismiss()
        }
    }

    // MARK: - Cursor management (split-view friendly)

    /// Width of the trailing strip where we yield cursor control to the
    /// parent HSplitView divider. Matches NSSplitView's divider width.
    private static let dividerCursorReserve: CGFloat = 9

    override func resetCursorRects() {
        // Instead of letting NSTextView paint the I-beam over the
        // entire bounds, set it only over the inset area that excludes
        // the trailing strip reserved for the split divider.
        let insetBounds = NSRect(
            x: bounds.origin.x,
            y: bounds.origin.y,
            width: max(0, bounds.width - Self.dividerCursorReserve),
            height: bounds.height
        )
        addCursorRect(insetBounds, cursor: .iBeam)
    }

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

        // Auto-close `{` after a `\cite*` command (LaTeX): insert `{}` and put
        // cursor between them. Keeps the document compilable and lets the
        // citation palette open immediately.
        if currentFormat == .latex,
           event.charactersIgnoringModifiers == "{",
           shouldAutoCloseCiteBrace() {
            let range = selectedRange()
            insertText("{}", replacementRange: range)
            // Move cursor back inside the new braces
            setSelectedRange(NSRange(location: range.location + 1, length: 0))
            return
        }

        // Let Helix handle it, or fall through to normal handling
        super.keyDown(with: event)

        // Update ghost text after any key press
        updateGhostText()
    }

    /// Returns true if the cursor is positioned right after a `\cite*` command name
    /// (so we should auto-close the brace the user is about to type).
    private func shouldAutoCloseCiteBrace() -> Bool {
        let ns = string as NSString
        let cursor = selectedRange().location
        var i = cursor - 1
        // Walk backwards over command name letters / `*`
        while i >= 0 {
            let cu = ns.character(at: i)
            let isLetter = (cu >= 65 && cu <= 90) || (cu >= 97 && cu <= 122)
            if isLetter || cu == 42 { i -= 1 } else { break }
        }
        guard i >= 0, ns.character(at: i) == 92 /* \ */ else { return false }
        let name = ns.substring(with: NSRange(location: i + 1, length: cursor - (i + 1))).lowercased()
        return name.hasPrefix("cite")
            || name.hasPrefix("parencite")
            || name.hasPrefix("textcite")
            || name.hasPrefix("autocite")
            || name.hasPrefix("footcite")
            || name.hasPrefix("smartcite")
            || name.hasPrefix("supercite")
            || name.hasPrefix("nocite")
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
