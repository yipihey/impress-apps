//
//  IOSSourceEditorView.swift
//  PublicationManagerCore
//
//  Cross-app iOS source editor (GUI-meld Phase 8). Moved here from
//  imprint-iOS so BOTH manuscript-editing companion apps (imprint-iOS and
//  imbib-iOS) share one touch-optimized Typst/LaTeX source editor instead
//  of forking two copies. macOS keeps its own AppKit editors — this file is
//  `#if os(iOS)` only.
//
//  Features:
//  - Full hardware-keyboard support with shortcuts (Cmd+B / Cmd+I / …)
//  - Apple Pencil Scribble support (inherited from UITextView)
//  - Touch-friendly text selection
//  - One-shot go-to-line navigation (driven by a document outline)
//  - tree-sitter syntax highlighting (ImpressSyntaxHighlight), driven by the
//    document's `DocumentFormat` through the same mapping the AppKit editor
//    uses — see `DocumentFormat+SyntaxHighlight.swift`
//

#if os(iOS)
import SwiftUI
import UIKit
import PDFKit
import ImpressSyntaxHighlight

// MARK: - iOS Source Editor View

/// A touch-optimized source code editor for Typst/LaTeX documents.
public struct IOSSourceEditorView: View {

    // MARK: - Properties

    /// The text content
    @Binding var text: String

    /// Current selection range
    @Binding var selection: NSRange?

    /// One-shot navigation request: set to a 1-based line number to scroll
    /// the editor there and place the caret at the line start. The editor
    /// resets it to `nil` once handled so repeated taps on the same line
    /// re-trigger navigation. Defaults to a constant `nil` binding so
    /// existing call sites compile unchanged.
    @Binding var goToLine: Int?

    /// Focus state
    @FocusState private var isFocused: Bool

    /// The manuscript's source format. Drives syntax highlighting (via
    /// `DocumentFormat.highlightLanguage`) — nothing else about the editor is
    /// format-specific yet. Defaults to `.typst`, the suite's default
    /// substrate, so existing call sites keep their behavior.
    let format: DocumentFormat

    /// Invoked on hardware-keyboard ⌘S — the manuscript editor's
    /// insert-citation shortcut (same grammar as the macOS chassis, where ⌘S
    /// opens the citation palette; manuscripts autosave, so ⌘S-as-save was a
    /// no-op here). nil → ⌘S falls back to dismissing the keyboard.
    let onInsertCitation: (() -> Void)?

    public init(
        text: Binding<String>,
        selection: Binding<NSRange?>,
        goToLine: Binding<Int?> = .constant(nil),
        format: DocumentFormat = .typst,
        onInsertCitation: (() -> Void)? = nil
    ) {
        self._text = text
        self._selection = selection
        self._goToLine = goToLine
        self.format = format
        self.onInsertCitation = onInsertCitation
    }

    // MARK: - Body

    public var body: some View {
        IOSSourceEditorRepresentable(
            text: $text,
            selection: $selection,
            goToLine: $goToLine,
            isFocused: $isFocused,
            format: format,
            onInsertCitation: onInsertCitation
        )
        .focused($isFocused)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

// MARK: - UIKit Representable

struct IOSSourceEditorRepresentable: UIViewRepresentable {

    // MARK: - Properties

    @Binding var text: String
    @Binding var selection: NSRange?
    @Binding var goToLine: Int?
    @FocusState.Binding var isFocused: Bool
    var format: DocumentFormat = .typst
    var onInsertCitation: (() -> Void)?

    /// The editor's monospaced face. Held in one place because the highlighter
    /// only writes `.foregroundColor`; every path that replaces the whole
    /// string has to restore this attribute.
    static let editorFont = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> UITextView {
        let textView = SourceTextView()
        textView.delegate = context.coordinator
        textView.onInsertCitation = onInsertCitation
        textView.font = Self.editorFont
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.keyboardType = .asciiCapable
        textView.backgroundColor = .systemBackground
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.alwaysBounceVertical = true

        // Enable Scribble
        textView.isUserInteractionEnabled = true

        // Configure keyboard
        configureKeyCommands(for: textView)

        // Seed the buffer + first full highlight before the view is on screen,
        // so the editor never flashes unhighlighted source.
        textView.text = text
        applyTypingAttributes(to: textView)
        rehighlightAll(textView, context: context)

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // The coordinator outlives this struct; refresh its copy so delegate
        // callbacks see the CURRENT format (and bindings) rather than the ones
        // captured when the coordinator was made.
        context.coordinator.parent = self
        (textView as? SourceTextView)?.onInsertCitation = onInsertCitation

        // A format change (e.g. the document loads and `.typst` flips to
        // `.latex`) needs a new grammar AND a full re-highlight.
        let formatChanged = context.coordinator.lastFormat != format
        context.coordinator.lastFormat = format

        if textView.text != text {
            let restore = textView.selectedRange
            textView.text = text
            applyTypingAttributes(to: textView)
            // Wholesale replacement: the coordinator's incremental tree is
            // meaningless now, so re-parse from scratch.
            rehighlightAll(textView, context: context)
            if restore.location + restore.length <= (textView.text as NSString).length {
                textView.selectedRange = restore
            }
        } else if formatChanged {
            applyTypingAttributes(to: textView)
            rehighlightAll(textView, context: context)
        }

        // Update selection if needed
        if let selection = selection,
           textView.selectedRange != selection {
            textView.selectedRange = selection
        }

        // Handle focus
        if isFocused && !textView.isFirstResponder {
            textView.becomeFirstResponder()
        } else if !isFocused && textView.isFirstResponder {
            textView.resignFirstResponder()
        }

        // Handle a one-shot go-to-line request (from the document outline).
        if let line = goToLine {
            let range = Self.range(forLine: line, in: textView.text ?? "")
            textView.selectedRange = range
            textView.scrollRangeToVisible(range)
            // Reset the pulse after this update cycle so the same line can be
            // navigated to again. Async avoids mutating @Binding mid-update.
            DispatchQueue.main.async {
                self.goToLine = nil
                self.selection = range
            }
        }
    }

    /// UTF-16 NSRange (zero length) at the start of the given 1-based line.
    /// Clamps out-of-range lines to the end of the text.
    static func range(forLine line: Int, in text: String) -> NSRange {
        let ns = text as NSString
        let length = ns.length
        guard line > 1 else { return NSRange(location: 0, length: 0) }

        var currentLine = 1
        var index = 0
        while index < length {
            let searchRange = NSRange(location: index, length: length - index)
            let newline = ns.rangeOfCharacter(from: .newlines, options: [], range: searchRange)
            if newline.location == NSNotFound { break }
            index = newline.location + newline.length
            currentLine += 1
            if currentLine == line {
                return NSRange(location: index, length: 0)
            }
        }
        return NSRange(location: min(index, length), length: 0)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Syntax Highlighting (tree-sitter via ImpressSyntaxHighlight)

    /// Full re-parse + re-highlight. Use on first load, on external buffer
    /// replacement, and when the format (grammar) changes — the same three
    /// cases the AppKit editor treats as "not an incremental edit".
    func rehighlightAll(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        guard let highlighter = format.resolveHighlighter(&coordinator.syntaxHighlighter) else {
            // No grammar for this format: strip any colors a previous grammar
            // left behind so the buffer reads as plain text.
            Self.resetColors(in: textView)
            return
        }
        let source = textView.text ?? ""
        highlighter.highlight(textStorage: textView.textStorage, source: source)
        Self.restoreFont(in: textView)
    }

    /// UITextView's `typingAttributes` are what newly typed characters inherit.
    /// The highlighter recolors after the fact, so seed them with the editor
    /// font + default color to avoid a one-character flash of the wrong style.
    func applyTypingAttributes(to textView: UITextView) {
        textView.typingAttributes = [
            .font: Self.editorFont,
            .foregroundColor: UIColor.label
        ]
    }

    /// The highlighter writes only `.foregroundColor`; re-assert the monospaced
    /// face over the whole buffer (mirrors the AppKit editor).
    static func restoreFont(in textView: UITextView) {
        let storage = textView.textStorage
        storage.addAttribute(
            .font, value: editorFont,
            range: NSRange(location: 0, length: storage.length))
    }

    static func resetColors(in textView: UITextView) {
        let storage = textView.textStorage
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: UIColor.label, range: full)
        storage.addAttribute(.font, value: editorFont, range: full)
        storage.endEditing()
    }

    // MARK: - Keyboard Commands

    private func configureKeyCommands(for textView: SourceTextView) {
        // Formatting commands
        textView.addKeyCommand(
            input: "b",
            modifierFlags: .command,
            action: #selector(SourceTextView.toggleBold)
        )
        textView.addKeyCommand(
            input: "i",
            modifierFlags: .command,
            action: #selector(SourceTextView.toggleItalic)
        )

        // Navigation commands
        textView.addKeyCommand(
            input: "g",
            modifierFlags: [.command],
            action: #selector(SourceTextView.goToLine)
        )

        // Save
        textView.addKeyCommand(
            input: "s",
            modifierFlags: .command,
            action: #selector(SourceTextView.saveDocument)
        )
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: IOSSourceEditorRepresentable

        /// Per-document tree-sitter highlighter (holds the parser + last tree,
        /// which is what makes `applyEdit` incremental). Same role as the
        /// AppKit editor coordinator's property of the same name.
        var syntaxHighlighter: SyntaxHighlighter?

        /// Last format the highlighter was built for, so a format flip rebuilds
        /// the grammar instead of silently keeping the old one.
        var lastFormat: DocumentFormat

        /// The edit reported by `shouldChangeTextIn` and not yet consumed by
        /// `textViewDidChange` — the only place UIKit tells us WHAT changed.
        private var pendingEdit: (range: NSRange, newLength: Int)?

        init(_ parent: IOSSourceEditorRepresentable) {
            self.parent = parent
            self.lastFormat = parent.format
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            pendingEdit = (range: range, newLength: (text as NSString).length)
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            applyIncrementalHighlight(to: textView)
        }

        /// Re-highlight after a keystroke using tree-sitter's incremental
        /// re-parse: only the subtrees the edit touched are rebuilt, instead of
        /// re-parsing the whole document per character.
        private func applyIncrementalHighlight(to textView: UITextView) {
            // Multi-stage input (dictation, IME, Scribble in progress): mutating
            // attributes under marked text breaks the input session. The final
            // commit fires another didChange, which highlights then.
            guard textView.markedTextRange == nil else { pendingEdit = nil; return }
            guard let highlighter = parent.format.resolveHighlighter(&syntaxHighlighter) else {
                pendingEdit = nil
                return
            }

            let source = textView.text ?? ""
            let selected = textView.selectedRange
            defer {
                IOSSourceEditorRepresentable.restoreFont(in: textView)
                if selected.location + selected.length <= (source as NSString).length {
                    textView.selectedRange = selected
                }
            }

            guard let edit = pendingEdit else {
                // No delta available (programmatic mutation) — full re-parse.
                highlighter.highlight(textStorage: textView.textStorage, source: source)
                return
            }
            pendingEdit = nil

            // SwiftTreeSitter parses UTF-16LE, so a tree-sitter "byte" offset is
            // a UTF-16 code-unit index × 2 (see SwiftTreeSitter's String+Data).
            let startUTF16 = edit.range.location
            let oldEndUTF16 = edit.range.location + edit.range.length
            let newEndUTF16 = edit.range.location + edit.newLength
            highlighter.applyEdit(
                newSource: source,
                startByte: startUTF16 * 2,
                oldEndByte: oldEndUTF16 * 2,
                newEndByte: newEndUTF16 * 2,
                textStorage: textView.textStorage
            )
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.selection = textView.selectedRange
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }
    }
}

// MARK: - Source Text View

/// Custom UITextView with keyboard command support
final class SourceTextView: UITextView {

    // MARK: - Key Commands

    /// Storage for registered key commands
    private var registeredKeyCommands: [UIKeyCommand] = []

    override var keyCommands: [UIKeyCommand]? {
        return registeredKeyCommands
    }

    func addKeyCommand(input: String, modifierFlags: UIKeyModifierFlags, action: Selector) {
        let command = UIKeyCommand(
            input: input,
            modifierFlags: modifierFlags,
            action: action
        )
        command.wantsPriorityOverSystemBehavior = true
        registeredKeyCommands.append(command)
    }

    // MARK: - Formatting Actions

    @objc func toggleBold() {
        wrapSelection(with: "*")
    }

    @objc func toggleItalic() {
        wrapSelection(with: "_")
    }

    @objc func insertCode() {
        wrapSelection(with: "`")
    }

    @objc func goToLine() {
        // Placeholder — the document outline drives go-to-line via the
        // `goToLine` binding.
    }

    /// Host hook for ⌘S insert-citation (set by the representable).
    var onInsertCitation: (() -> Void)?

    @objc func saveDocument() {
        // ⌘S — the chassis-wide insert-citation shortcut (manuscripts
        // autosave; the old resign-first-responder "save" was a no-op).
        // Hosts without a citation picker keep the keyboard-dismiss fallback.
        if let onInsertCitation {
            onInsertCitation()
            return
        }
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    // MARK: - Helpers

    private func wrapSelection(with wrapper: String) {
        guard let currentRange = selectedTextRange else { return }

        let selectedText = text(in: currentRange) ?? ""
        let wrappedText = "\(wrapper)\(selectedText)\(wrapper)"

        replace(currentRange, withText: wrappedText)

        // Adjust selection to be inside the wrapper
        if selectedText.isEmpty {
            if let newPosition = position(from: currentRange.start, offset: wrapper.count),
               let newRange = textRange(from: newPosition, to: newPosition) {
                self.selectedTextRange = newRange
            }
        }
    }
}

// MARK: - iOS PDF Preview View

/// Live PDF preview backed by PDFKit, fed from a compile pipeline's PDF data.
public struct IOSPDFPreviewView: View {
    let pdfData: Data?
    let isCompiling: Bool

    public init(pdfData: Data?, isCompiling: Bool) {
        self.pdfData = pdfData
        self.isCompiling = isCompiling
    }

    public var body: some View {
        ZStack {
            if let data = pdfData {
                IOSPDFKitView(data: data)
            } else {
                VStack {
                    Image(systemName: "doc.text")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)

                    Text("PDF Preview")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Text(isCompiling ? "Compiling…" : "Compile the document to see the preview")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if isCompiling {
                ProgressView()
                    .controlSize(.large)
                    .padding(20)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

/// PDFKit wrapper. Reloads only when the data actually changes (guarded by
/// a byte-count + first-bytes fingerprint in the coordinator) so SwiftUI
/// re-renders don't reset the scroll position.
private struct IOSPDFKitView: UIViewRepresentable {
    let data: Data

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastFingerprint: Int = 0
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemGroupedBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        var hasher = Hasher()
        hasher.combine(data.count)
        hasher.combine(data.prefix(64))
        let fingerprint = hasher.finalize()
        guard fingerprint != context.coordinator.lastFingerprint else { return }
        context.coordinator.lastFingerprint = fingerprint

        // Preserve the page the user was reading across recompiles.
        let currentPageIndex = view.currentPage.flatMap { view.document?.index(for: $0) }
        view.document = PDFDocument(data: data)
        if let idx = currentPageIndex,
           let doc = view.document, idx < doc.pageCount,
           let page = doc.page(at: idx) {
            view.go(to: page)
        }
    }
}

// MARK: - Preview

#Preview {
    IOSSourceEditorView(
        text: .constant("= Hello World\n\nThis is a test document."),
        selection: .constant(nil)
    )
}
#endif
