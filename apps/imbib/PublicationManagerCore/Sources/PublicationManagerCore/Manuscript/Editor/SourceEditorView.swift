#if os(macOS)
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
///
/// GUI-meld Phase 3: moved from the imprint app target into PublicationManagerCore
/// so imbib and imprint share one editor. App-specific behaviours (AI completion,
/// AI author-tasks, citation search, LaTeX completion, collaboration presence) are
/// injected via `ManuscriptEditorEnvironment` rather than reached through
/// app-target singletons.
public struct SourceEditorView: View {
    @Binding var source: String
    @Binding var cursorPosition: Int
    var syntaxMode: DocumentFormat = .typst
    var highlight: EditorHighlightRequest? = nil
    var onSelectionChange: ((String, NSRange) -> Void)?
    /// Which manuscript this editor is editing, when it is editing one.
    ///
    /// Only used to register with `ManuscriptCitationInserter`, so imbib's
    /// papers window (and imprint's HTTP API, and an agent) can put a cite key
    /// at this editor's caret. `nil` — a scratch editor — registers nothing.
    var manuscriptID: UUID? = nil
    /// An editor that outlives this view (a `source` pane's session,
    /// ADR-0031 D6). `nil` — the Source tab and the standalone editor window —
    /// builds the editor with this view and loses it with this view, exactly
    /// as before.
    var host: TypstEditorHost? = nil

    @AppStorage("imprint.helix.isEnabled") private var helixModeEnabled = false
    @AppStorage("imprint.helix.showModeIndicator") private var helixShowModeIndicator = true
    /// Mathematica-style cell brackets in the right margin (click to select
    /// sections/paragraphs; right-click Copy/Cut/Delete).
    @AppStorage("imprint.editor.showCellBrackets") private var showCellBrackets = true

    @State private var helixState = HelixState()
    private let inlineCompletionService = ManuscriptEditorEnvironment.shared.inlineCompletion

    public init(
        source: Binding<String>,
        cursorPosition: Binding<Int>,
        syntaxMode: DocumentFormat = .typst,
        highlight: EditorHighlightRequest? = nil,
        manuscriptID: UUID? = nil,
        onSelectionChange: ((String, NSRange) -> Void)? = nil
    ) {
        self._source = source
        self._cursorPosition = cursorPosition
        self.syntaxMode = syntaxMode
        self.highlight = highlight
        self.manuscriptID = manuscriptID
        self.onSelectionChange = onSelectionChange
    }

    init(
        source: Binding<String>,
        cursorPosition: Binding<Int>,
        syntaxMode: DocumentFormat,
        highlight: EditorHighlightRequest?,
        manuscriptID: UUID?,
        host: TypstEditorHost?,
        onSelectionChange: ((String, NSRange) -> Void)?
    ) {
        self.init(
            source: source, cursorPosition: cursorPosition, syntaxMode: syntaxMode,
            highlight: highlight, manuscriptID: manuscriptID, onSelectionChange: onSelectionChange)
        self.host = host
    }

    /// The Helix state the editor's adaptor was built with: the host's when
    /// there is one, since the adaptor outlives this view.
    private var activeHelixState: HelixState { host?.helixState ?? helixState }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Color.clear expands to fill available space, forcing ZStack to full size
            Color.clear

            TypstEditorRepresentable(
                source: $source,
                cursorPosition: $cursorPosition,
                syntaxMode: syntaxMode,
                helixState: activeHelixState,
                helixEnabled: helixModeEnabled,
                showCellBrackets: showCellBrackets,
                inlineCompletionService: inlineCompletionService,
                highlight: highlight,
                manuscriptID: manuscriptID,
                host: host,
                onSelectionChange: onSelectionChange
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Helix mode indicator
            if helixModeEnabled && helixShowModeIndicator {
                HelixModeIndicator(state: activeHelixState, position: .bottomLeft)
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
                        guard let cite = mode.citationInsert else { return }
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
                        case .markdown:
                            snippet = "![\(title)](figures/\(ref.id.uuidString).\(ref.format ?? "png"))"
                        case .plaintext:
                            snippet = "[figure: figures/\(ref.id.uuidString).\(ref.format ?? "png") — \(title)]"
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
    /// Per-surface appearance override ("follow" | "light" | "dark") — lets
    /// the editor be dark while the rest of the app is light, or vice versa.
    /// AppStorage is a DynamicProperty, so changes re-run updateNSView.
    @AppStorage("editorAppearance") private var editorAppearance = "follow"

    static func appearanceOverride(_ raw: String) -> NSAppearance? {
        switch raw {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil  // inherit the app/window appearance
        }
    }

    @Binding var source: String
    @Binding var cursorPosition: Int
    let syntaxMode: DocumentFormat
    let helixState: HelixState
    let helixEnabled: Bool
    var showCellBrackets: Bool = true
    let inlineCompletionService: any InlineCompletionProviding
    var highlight: EditorHighlightRequest? = nil
    /// See `SourceEditorView.manuscriptID`.
    var manuscriptID: UUID? = nil
    /// See `SourceEditorView.host`.
    var host: TypstEditorHost? = nil
    var onSelectionChange: ((String, NSRange) -> Void)?

    /// Two shapes. Without a host, the editor's scroll view IS this
    /// representable's view: built here, torn down with it (the Source tab,
    /// unchanged). With a host (a `source` pane), the view is a plain
    /// container and the host's editor — built once, by the same
    /// `makeEditor` — is moved into it: a split or a swap rebuilds the pane's
    /// SwiftUI structure, and the SAME `NSTextView`, text and undo stack
    /// arrive in the new place (ADR-0031 D6). A container rather than the
    /// scroll view itself, so the old representable's teardown can tell
    /// whether the editor is still its own: SwiftUI may build the new pane
    /// before it dismantles the old one.
    func makeNSView(context: Context) -> NSView {
        guard let host else { return makeEditor(coordinator: context.coordinator) }
        if host.scrollView == nil {
            host.adopt(makeEditor(coordinator: context.coordinator))
        }
        let container = NSView()
        host.mount(in: container)
        return container
    }

    /// Build the editor: the scroll view, the `TypstTextView` and everything
    /// the coordinator wires into it. The one construction path — the Source
    /// tab calls it per mount, a pane session's host calls it once.
    func makeEditor(coordinator: Coordinator) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.appearance = Self.appearanceOverride(editorAppearance)

        let textView = TypstTextView()
        textView.delegate = coordinator
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

        // Writing Tools (Apple Intelligence): request the full experience. We
        // always drive it from a *bounded* selection — a cell bracket's element
        // (see BracketRulerNSView) or the user's own selection — never the whole
        // markup document, which is what made it stall then fail.
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .complete
        }

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
        coordinator.helixAdaptor = adaptor

        // Set up inline completion service
        textView.inlineCompletionService = inlineCompletionService

        // Add ghost text overlay
        let ghostTextView = GhostTextNSView(frame: .zero)
        ghostTextView.textFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.addSubview(ghostTextView)
        textView.ghostTextView = ghostTextView

        scrollView.documentView = textView
        coordinator.textView = textView

        // Hover preview for cite keys
        textView.hoverController = coordinator.hoverController
        textView.currentFormat = syntaxMode

        // Focus-scoped ⌘S → citation insert.
        textView.onManualCitation = { [weak coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.insertCitationManually(in: textView)
        }

        // Cell-bracket ruler (right margin). Reserve space via the container
        // inset so text never flows under the brackets.
        if showCellBrackets {
            let ruler = BracketRulerNSView(frame: .zero)
            ruler.textView = textView
            ruler.autoresizingMask = [.minXMargin, .height]
            configureRulerAI(ruler)
            textView.bracketRuler = ruler
            textView.addSubview(ruler)
            textView.textContainerInset = NSSize(width: BracketRulerNSView.gutterWidth, height: 4)
        }
        // AI tasks on a plain text selection use the same catalog + handler.
        textView.aiTasks = InlineAITaskCatalog.tasks()
        textView.aiRequestHandler = { actionId, range in
            InlineAITaskCatalog.post(actionId: actionId, range: range)
        }

        // Set initial text
        textView.string = source
        applySyntaxHighlighting(to: textView)
        if showCellBrackets { rebuildBrackets(textView, coordinator: coordinator, force: true) }

        return scrollView
    }

    func updateNSView(_ view: NSView, context: Context) {
        // A host's editor has ONE coordinator, shared by every representable
        // that mounts it. SwiftUI may build the new pane before it dismantles
        // the old one, and an update pass on the OLD representable would then
        // repoint the shared delegate at the stale pane's bindings and
        // re-register the old pane's citation target (review PH-L1). Only
        // the representable whose container holds the editor may touch it.
        if let host, !host.holdsEditor(in: view) { return }
        // Then first, before any other early return (impress-swiftui-pitfalls
        // rule 2) — for a host's editor this is also how the ONE coordinator
        // learns which pane's bindings it now serves.
        context.coordinator.parent = self
        guard let scrollView = host?.scrollView ?? (view as? NSScrollView) else { return }
        scrollView.appearance = Self.appearanceOverride(editorAppearance)
        guard let textView = scrollView.documentView as? TypstTextView else { return }

        // (The `parent = self` refresh above keeps delegate callbacks
        // reading current bindings. Without it, the coordinator keeps the
        // *initial* struct — which defaults `syntaxMode` to `.typst` — even
        // after the document loads as LaTeX. The result: on every keystroke
        // textDidChange would dispatch to the typst highlighter, painting
        // `\b`, `\d`, `\u` etc. as `@constant.character.escape` (red).)
        context.coordinator.registerForCitationInsertion(manuscriptID)

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
        if let host {
            // A pane's editor knows which document it shows: a different
            // manuscript is a SWITCH (its own undo history comes with it), the
            // same one with other text is an external change.
            switch host.present(document: manuscriptID, text: source, in: textView) {
            case .unchanged:
                break
            case .switched:
                context.coordinator.syntaxHighlighter = nil
                applySyntaxHighlighting(to: textView)
            case .external:
                applySyntaxHighlighting(to: textView)
                // The caret moved with its text. `cursorPosition` in THIS
                // pass still holds where it was, and the jump block below
                // would put it back there — 30 characters early after a
                // co-author's 30-character insertion above it. Skip the jump
                // now; hand the moved caret to the binding after the pass.
                let caret = textView.selectedRange().location
                let coordinator = context.coordinator
                let binding = $cursorPosition
                coordinator.lastReportedCursorPosition = cursorPosition
                DispatchQueue.main.async {
                    coordinator.lastReportedCursorPosition = caret
                    binding.wrappedValue = caret
                }
            }
        } else if textView.string != source {
            let selectedRange = textView.selectedRange()
            textView.string = source
            applySyntaxHighlighting(to: textView)

            // Restore selection
            if selectedRange.location <= source.count {
                textView.setSelectedRange(selectedRange)
            }
        }

        // Cell brackets: add/remove per the toggle, then refresh from the text.
        syncBracketRuler(textView, coordinator: context.coordinator)

        // Handle programmatic cursor navigation (outline click, or a jump back
        // from the compiled preview).
        let requestedPosition = cursorPosition
        if requestedPosition != context.coordinator.lastReportedCursorPosition,
           requestedPosition >= 0,
           requestedPosition <= textView.string.count {
            context.coordinator.lastReportedCursorPosition = requestedPosition
            let range = NSRange(location: requestedPosition, length: 0)
            textView.setSelectedRange(range)
            Self.revealCaret(range, in: textView, scrollView: scrollView)

            // On a freshly-created editor (switching back to the Source tab)
            // the scroll view has not been laid out at its final size yet, so
            // the first measurement can be short. Re-apply once the geometry
            // settles; it is a no-op when the first attempt already landed.
            if !context.coordinator.didApplyInitialScroll {
                context.coordinator.didApplyInitialScroll = true
                DispatchQueue.main.async { [weak textView, weak scrollView] in
                    guard let textView, let scrollView else { return }
                    Self.revealCaret(range, in: textView, scrollView: scrollView)
                }
            }

            // Make the text view first responder so the cursor blinks
            textView.window?.makeFirstResponder(textView)
        }

        // Programmatic select-and-reveal (diagnostics click). After the caret
        // block on purpose: when both fire in one pass, the selection wins.
        if let highlight,
           highlight.generation != context.coordinator.lastHighlightGeneration {
            context.coordinator.lastHighlightGeneration = highlight.generation
            let textLength = (textView.string as NSString).length
            let location = min(max(0, highlight.range.location), textLength)
            let length = min(max(0, highlight.range.length), textLength - location)
            let range = NSRange(location: location, length: length)
            textView.setSelectedRange(range)
            Self.revealCaret(NSRange(location: location, length: 0), in: textView, scrollView: scrollView)
            textView.window?.makeFirstResponder(textView)
            logInfo("highlight request → \(range)", category: "manuscript-sync")
        }
    }

    /// Scroll `range` to the top of the visible area.
    ///
    /// Layout MUST be forced first: `boundingRect(forGlyphRange:)` reports
    /// against whatever has been laid out so far, and NSLayoutManager lays out
    /// lazily. On a newly-created editor almost nothing is laid out, so the
    /// target line measures near y=0 and the view "scrolls" to the top — which
    /// is exactly the symptom of a preview→source jump landing at the
    /// beginning of the document instead of at the click.
    private static func revealCaret(_ range: NSRange, in textView: NSTextView, scrollView: NSScrollView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            textView.scrollRangeToVisible(range)
            return
        }
        // Force layout of everything up to and including the target line.
        let head = NSRange(location: 0, length: min(range.location + 1, (textView.string as NSString).length))
        layoutManager.ensureLayout(forCharacterRange: head)

        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let targetY = lineRect.origin.y
        logInfo("reveal caret at offset \(range.location) → y=\(Int(targetY))",
                category: "manuscript-sync")
        let visibleHeight = scrollView.contentView.bounds.height
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - visibleHeight)
        let clampedY = min(max(0, targetY), maxY)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// A host's editor keeps ONE coordinator — it is the text view's
    /// delegate and holds the Helix adaptor, the palettes and the highlighter
    /// — so every representable that mounts the editor gets that one.
    func makeCoordinator() -> Coordinator {
        if let existing = host?.coordinator { return existing }
        let coordinator = Coordinator(self)
        host?.coordinator = coordinator
        return coordinator
    }

    /// SwiftUI is done with this editor — stop offering it as a citation target.
    /// Without this, a closed manuscript's editor stays registered and an
    /// insert aimed at it reports success into a dead text view.
    ///
    /// A host's editor is DETACHED, never destroyed, and only when it is still
    /// in this representable's container: after a split the new pane may
    /// already have moved it.
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            if let host = coordinator.host {
                host.detach(from: view)
            } else {
                coordinator.resignCitationInsertion()
            }
        }
    }

    // MARK: - Syntax Highlighting (tree-sitter via ImpressSyntaxHighlight)

    /// Tree-sitter language for the current syntax mode; nil = no grammar
    /// (markdown/plaintext render unhighlighted until a grammar is vendored).
    ///
    /// The mapping itself lives on `DocumentFormat` (see
    /// `DocumentFormat+SyntaxHighlight.swift`) so the AppKit and UIKit editors
    /// cannot drift apart.
    private var highlightLanguage: ImpressLanguage? { syntaxMode.highlightLanguage }

    /// Get or create a SyntaxHighlighter for the current syntax mode from the coordinator.
    private func syntaxHighlighter(for coordinator: Coordinator) -> SyntaxHighlighter? {
        syntaxMode.resolveHighlighter(&coordinator.syntaxHighlighter)
    }

    private func applySyntaxHighlighting(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        guard let coordinator = textView.delegate as? Coordinator else { return }

        guard let highlighter = syntaxHighlighter(for: coordinator) else { return }
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

    /// Reconcile the bracket ruler with the `showCellBrackets` toggle (adding or
    /// removing it + adjusting the text-container inset), then rebuild its nodes.
    private func syncBracketRuler(_ textView: TypstTextView, coordinator: Coordinator) {
        if showCellBrackets {
            if textView.bracketRuler == nil {
                let ruler = BracketRulerNSView(frame: NSRect(
                    x: textView.bounds.width - BracketRulerNSView.gutterWidth, y: 0,
                    width: BracketRulerNSView.gutterWidth, height: textView.bounds.height))
                ruler.textView = textView
                ruler.autoresizingMask = [.minXMargin, .height]
                configureRulerAI(ruler)
                textView.bracketRuler = ruler
                textView.addSubview(ruler)
                textView.textContainerInset = NSSize(width: BracketRulerNSView.gutterWidth, height: 4)
            }
            rebuildBrackets(textView, coordinator: coordinator)
            textView.bracketRuler?.needsDisplay = true
        } else if let ruler = textView.bracketRuler {
            ruler.removeFromSuperview()
            textView.bracketRuler = nil
            textView.textContainerInset = NSSize(width: 0, height: 4)
        }
    }

    /// Wire the bracket ruler's AI submenu: the curated task list + a handler
    /// that posts `.runInlineAITask` (observed by ContentView) with the picked
    /// task and the bracket's source range.
    private func configureRulerAI(_ ruler: BracketRulerNSView) {
        ruler.aiTasks = InlineAITaskCatalog.tasks()
        ruler.aiRequestHandler = { actionId, range in
            InlineAITaskCatalog.post(actionId: actionId, range: range)
        }
    }

    /// Rebuild the cell-bracket structure from the current text and hand it to
    /// the ruler. Skips work when the source is unchanged (unless `force`).
    private func rebuildBrackets(_ textView: TypstTextView, coordinator: Coordinator, force: Bool = false) {
        guard let ruler = textView.bracketRuler else { return }
        let src = textView.string
        // Markdown/plaintext have no Typst/LaTeX heading grammar — show a
        // flat (empty) structure instead of misparsing with the Typst rules.
        guard syntaxMode == .typst || syntaxMode == .latex else {
            ruler.update(nodes: [])
            return
        }
        let fmt: SectionFormat = (syntaxMode == .latex) ? .latex : .typst
        // Rebuild when the source OR the detected format changes. Format matters
        // because it's often still the default (.typst) at first build and only
        // flips to .latex after the document loads — without this the structure
        // would stay stuck on the wrong heading grammar (0 headings → flat).
        if !force,
           coordinator.lastStructureSource == src,
           coordinator.lastStructureFormat == syntaxMode {
            return
        }
        coordinator.lastStructureSource = src
        coordinator.lastStructureFormat = syntaxMode
        ruler.update(nodes: DocumentStructure.build(source: src, format: fmt))
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TypstEditorRepresentable
        /// The pane session's editor host this coordinator belongs to, if any.
        weak var host: TypstEditorHost?
        weak var textView: NSTextView?
        var helixAdaptor: NSTextViewHelixAdaptor?
        /// Last source the bracket structure was computed from (debounce).
        var lastStructureSource: String = ""
        /// Last format the bracket structure was computed for — rebuild when the
        /// document's detected format flips (e.g. default .typst → .latex on load).
        var lastStructureFormat: DocumentFormat = .typst
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
        /// Generation of the last consumed `EditorHighlightRequest`.
        var lastHighlightGeneration: Int = 0
        /// Whether the first programmatic caret reveal has run for this editor.
        /// Guards a one-shot deferred retry while the view is still sizing.
        var didApplyInitialScroll = false

        init(_ parent: TypstEditorRepresentable) {
            self.parent = parent
            self.host = parent.host
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
                let completions = await ManuscriptEditorEnvironment.shared.latexCompletions(
                    capturedPrefix,
                    capturedSource,
                    capturedOffset
                )
                self?.cachedLaTeXCompletions = completions
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

            // Cell brackets: the structure + geometry changed — redraw. The node
            // ranges are rebuilt shortly after via updateNSView.
            if let typst = textView as? TypstTextView { typst.bracketRuler?.needsDisplay = true }
        }

        // MARK: - Citation insertion from outside the editor

        /// The manuscript this editor is currently registered as.
        private var registeredManuscriptID: UUID?

        /// Caret position immediately after a citation this editor inserted
        /// programmatically.
        ///
        /// A finished `@key` under the caret looks exactly like one being
        /// typed, so the inline palette opened over the editor every time
        /// imbib's papers window cited something. The palette stays shut while
        /// the caret is still at that spot, and works normally as soon as the
        /// author moves or types.
        private var caretAfterInsertedCitation: Int?

        /// Offer this editor as the citation target for `manuscriptID`.
        /// Idempotent — `updateNSView` calls it on every refresh.
        @MainActor
        func registerForCitationInsertion(_ manuscriptID: UUID?) {
            guard registeredManuscriptID != manuscriptID else { return }
            if let previous = registeredManuscriptID {
                ManuscriptCitationInserter.shared.unregister(manuscriptID: previous)
            }
            registeredManuscriptID = manuscriptID
            guard let manuscriptID else { return }
            ManuscriptCitationInserter.shared.register(
                manuscriptID: manuscriptID,
                format: { [weak self] in self?.parent.syntaxMode ?? .typst },
                insert: { [weak self] keys in
                    self?.insertCitationKeys(keys) ?? .refused("the editor went away")
                },
                openPalette: { [weak self] in
                    guard let self, let textView = self.textView else { return false }
                    self.insertCitationManually(in: textView)
                    return true
                }
            )
        }

        @MainActor
        func resignCitationInsertion() {
            if let previous = registeredManuscriptID {
                ManuscriptCitationInserter.shared.unregister(manuscriptID: previous)
            }
            registeredManuscriptID = nil
        }

        /// A citation with whatever spacing it needs to stand apart from the
        /// text around it.
        ///
        /// BOTH sides matter, and only the leading side was handled at first:
        /// a Typst `@key` runs until a non-word character, so inserting one
        /// immediately before existing text produced `@a@b` and `@key= Heading`
        /// — one mangled label that Typst then reports as "does not exist",
        /// naming a key nobody typed. Punctuation that naturally follows a
        /// citation (`.`, `,`, a closing bracket) is left tight against it.
        static func spaced(
            _ citation: String, insertedInto text: NSString, at location: Int, format: DocumentFormat
        ) -> String {
            let opensTight = CharacterSet(charactersIn: "([{~,;")
            let closesTight = CharacterSet(charactersIn: ".,;:!?)]}\u{2019}\u{201D}")
            func character(at index: Int) -> Unicode.Scalar? {
                guard index >= 0, index < text.length else { return nil }
                return Unicode.Scalar(text.character(at: index))
            }
            let before = character(at: location - 1)
            let after = character(at: location)
            let needsLeading = before.map {
                !CharacterSet.whitespacesAndNewlines.contains($0) && !opensTight.contains($0)
            } ?? false
            let needsTrailing = after.map {
                !CharacterSet.whitespacesAndNewlines.contains($0) && !closesTight.contains($0)
            } ?? false
            return (needsLeading ? " " : "") + citation + (needsTrailing ? " " : "")
        }

        /// Put cite keys in the document at the caret, in the document's own
        /// citation syntax.
        ///
        /// With text selected the citation goes AFTER the selection rather
        /// than replacing it: the author selected a claim, and a citation
        /// belongs at its end. A space is added when the character before the
        /// insertion point would otherwise run into the citation.
        @MainActor
        func insertCitationKeys(_ keys: [String]) -> CitationInsertOutcome {
            guard let textView, let textStorage = textView.textStorage else {
                return .refused("the editor is not ready")
            }
            guard textView.isEditable else {
                return .refused("this manuscript is not editable here")
            }
            let citation = ManuscriptCitationInserter.citationText(
                for: keys, format: parent.syntaxMode)
            guard !citation.isEmpty else { return .nothingToInsert }

            let selection = textView.selectedRange()
            let location = NSMaxRange(selection)
            let text = textStorage.string as NSString
            let insertText = Self.spaced(
                citation, insertedInto: text, at: location, format: parent.syntaxMode)
            let insertRange = NSRange(location: location, length: 0)
            guard textView.shouldChangeText(in: insertRange, replacementString: insertText) else {
                return .refused("the editor refused the edit")
            }
            let caret = location + (insertText as NSString).length
            caretAfterInsertedCitation = caret
            textStorage.replaceCharacters(in: insertRange, with: insertText)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
            citationPalette.dismiss()

            // Same signal the inline palette posts, so a host that tracks
            // insertions sees both paths identically.
            for key in keys {
                NotificationCenter.default.post(
                    name: .inlineCitationInserted, object: nil, userInfo: ["citeKey": key])
            }
            return .inserted(citation)
        }

        /// Manual (⌘S) citation insert: drop the format-appropriate citation
        /// scaffold at the cursor, then open the palette positioned inside it.
        /// The palette's normal insert(row:) then fills the key.
        @MainActor
        func insertCitationManually(in textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            let format = parent.syntaxMode
            let caret = textView.selectedRange().location

            // Scaffold + where the key goes (empty insertion range inside it).
            let scaffold: String
            let keyOffset: Int   // offset from caret to the key insertion point
            switch format {
            case .latex:
                scaffold = "\\cite{}"
                keyOffset = 6      // between the braces
            case .typst, .markdown:
                scaffold = "@"     // markdown: pandoc-style @key
                keyOffset = 1      // right after @
            case .plaintext:
                return             // no citation syntax in plain text
            }

            let insertRange = NSRange(location: caret, length: 0)
            if textView.shouldChangeText(in: insertRange, replacementString: scaffold) {
                textStorage.replaceCharacters(in: insertRange, with: scaffold)
                textView.didChangeText()
                let keyLocation = caret + keyOffset
                textView.setSelectedRange(NSRange(location: keyLocation, length: 0))

                let citedKeys = ManuscriptEditorEnvironment.shared.citedKeys()
                citationPalette.show(
                    in: textView,
                    at: NSRange(location: keyLocation, length: 0),
                    initialQuery: "",
                    alreadyCitedKeys: citedKeys,
                    format: format
                )
            }
        }

        /// Detects if the current caret position is inside a citation trigger and
        /// shows/hides the inline palette accordingly. Runs on MainActor because
        /// BibliographyGenerator and AppKit views are main-isolated.
        @MainActor
        private func maybeShowCitationPalette(in textView: NSTextView, at cursorLocation: Int) {
            if let inserted = caretAfterInsertedCitation {
                if cursorLocation == inserted {
                    if citationPalette.isShowing { citationPalette.dismiss() }
                    return
                }
                caretAfterInsertedCitation = nil
            }
            let format = parent.syntaxMode
            if let trigger = CitationPaletteTriggerDetector.detect(
                in: textView.string,
                at: cursorLocation,
                format: format
            ) {
                logInfo("CitationPalette: trigger at loc=\(cursorLocation), query='\(trigger.initialQuery)', format=\(format)", category: "citation-palette")
                let citedKeys = ManuscriptEditorEnvironment.shared.citedKeys()
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

            // Update collaboration cursor (host-provided; no-op by default)
            ManuscriptEditorEnvironment.shared.presenceCursorHook(textView)
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
    var inlineCompletionService: (any InlineCompletionProviding)?

    /// Ghost text overlay view
    var ghostTextView: GhostTextNSView?

    /// Cell-bracket ruler pinned to the right margin (nil when disabled).
    var bracketRuler: BracketRulerNSView?

    // MARK: - Per-document undo (a pane session's editor)

    /// The undo manager of the document this view shows, when a pane session
    /// owns the editor (`TypstEditorHost`). One per manuscript, so switching
    /// documents in a pane never mixes their histories, and one that lives
    /// with the editor rather than the window, so it survives the editor
    /// moving between panes. `nil` — the Source tab — leaves undo exactly as
    /// it was: the responder chain's (the window's) undo manager.
    var documentUndoManager: UndoManager?

    override var undoManager: UndoManager? {
        documentUndoManager ?? super.undoManager
    }

    /// Edit ▸ Undo / Redo go to the responder chain; claim them only when
    /// this view has its own history, so the Source tab's ⌘Z still reaches
    /// the window's undo manager as before.
    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(undo(_:)) || aSelector == #selector(redo(_:)) {
            return documentUndoManager != nil
        }
        return super.responds(to: aSelector)
    }

    @objc func undo(_ sender: Any?) {
        documentUndoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        documentUndoManager?.redo()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let history = documentUndoManager {
            if item.action == #selector(undo(_:)) {
                (item as? NSMenuItem)?.title = history.undoMenuItemTitle
                return history.canUndo
            }
            if item.action == #selector(redo(_:)) {
                (item as? NSMenuItem)?.title = history.redoMenuItemTitle
                return history.canRedo
            }
        }
        return super.validateUserInterfaceItem(item)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Keep the bracket ruler covering the full document height at the right.
        if let ruler = bracketRuler {
            ruler.frame = NSRect(
                x: newSize.width - BracketRulerNSView.gutterWidth,
                y: 0,
                width: BracketRulerNSView.gutterWidth,
                height: newSize.height
            )
        }
    }

    // MARK: - Hover Preview

    /// Hover preview popover controller for cite keys.
    var hoverController: CiteKeyHoverController?
    /// Current document format (set by the coordinator) — used to pick the right cite-key parser.
    var currentFormat: DocumentFormat = .typst
    /// ⌘S in the focused editor: insert a citation at the cursor (GUI-meld §5,
    /// focus-scoped — the chassis ⌘S smart-search only fires when the editor
    /// is NOT first responder). Set by the coordinator.
    var onManualCitation: (@MainActor () -> Void)?
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
        // Deferred, not immediate: moving the pointer *into* the hover popover
        // exits this text view, and an immediate dismiss would make the
        // popover's button unreachable.
        hoverController?.scheduleDismiss()
    }

    private func handleHover(event: NSEvent) {
        let pointInView = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: pointInView)
        // `characterIndexForInsertion` answers in UTF-16 code units, so the
        // bound must be the NSString length. `string.count` is a *Character*
        // count and is smaller than the buffer for any emoji/astral text —
        // hovering the tail of such a document silently stopped working.
        guard charIndex != NSNotFound, charIndex >= 0,
              charIndex < (string as NSString).length else {
            hoverController?.scheduleDismiss()
            return
        }
        // Detection is the canonical Rust scanner (see ManuscriptCiteKeyLocator)
        // — the same one iOS long-press, the compile-time bibliography and the
        // usage index use. The strict (half-open) probe is deliberate: it is
        // what the hand-rolled scanner this replaced did, so the hover target
        // is unchanged. `nearUTF16Offset` is touch tolerance for iOS and would
        // widen the mouse hit area.
        if let hit = ManuscriptCiteKeyLocator.citeKey(
            in: string, atUTF16Offset: charIndex, format: currentFormat
        ) {
            // `hitRange`, not `keyRange`: the span the reader sees as "the
            // citation" — it includes Typst's `@` sigil and equals the key for
            // LaTeX, so the popover anchors to the whole token on both.
            hoverController?.show(in: self, citeKey: hit.key, range: hit.hitRange)
        } else {
            hoverController?.scheduleDismiss()
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

    // MARK: - Find (Cmd+F and friends)

    /// Route the standard Find shortcuts to the NSTextView find bar
    /// (`usesFindBar = true`). SwiftUI's custom menu commands don't wire a
    /// Find menu item, so Cmd+F never reaches the responder chain otherwise.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit offers a key equivalent to EVERY view in the window, not only
        // the first responder; without this the editor answered ⌘F/⌘G/⌘E/⌘S
        // and the AI chords while another pane (the Papers panel's search, a
        // list) had focus.
        guard ownsKeyboardFocus else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()

        // AI Assist shortcuts (⌃⌘<letter>) — run the task on the selection, or
        // on the caret's paragraph when there's no selection. Same grammar shown
        // in the bracket / selection "AI Assist" menu section.
        if let key, let actionID = InlineAITaskCatalog.actionID(forKey: key, modifiers: mods) {
            InlineAITaskCatalog.post(actionId: actionID, range: aiTargetRange())
            return true
        }

        // Only claim these when Cmd is held (and not while Helix owns the keys
        // in a modal, non-insert mode — Helix insert mode behaves like normal).
        if mods == .command {
            switch key {
            case "f":
                performTextFinderAction(tag: NSTextFinder.Action.showFindInterface.rawValue)
                return true
            case "g":
                performTextFinderAction(tag: NSTextFinder.Action.nextMatch.rawValue)
                return true
            case "e":
                performTextFinderAction(tag: NSTextFinder.Action.setSearchString.rawValue)
                return true
            case "s":
                // Focus-scoped ⌘S: insert a citation. Only reached while the
                // editor is first responder; elsewhere ⌘S is the chassis
                // smart-search overlay.
                if let onManualCitation {
                    onManualCitation()
                    return true
                }
            default:
                break
            }
        } else if mods == [.command, .shift], key == "g" {
            performTextFinderAction(tag: NSTextFinder.Action.previousMatch.rawValue)
            return true
        } else if mods == [.command, .option], key == "f" {
            performTextFinderAction(tag: NSTextFinder.Action.showReplaceInterface.rawValue)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// This editor, or the find bar inside its scroll view, has keyboard focus.
    private var ownsKeyboardFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === self { return true }
        // Typing in the find bar: the field editor's delegate is the find
        // bar's text field, which lives inside this editor's scroll view.
        if let fieldEditor = responder as? NSTextView, fieldEditor.isFieldEditor,
           let field = fieldEditor.delegate as? NSView,
           let scrollView = enclosingScrollView {
            return field.isDescendant(of: scrollView)
        }
        return false
    }

    /// Invoke a text-finder action via a lightweight sender carrying the tag,
    /// since `performTextFinderAction(_:)` reads `sender.tag`.
    private func performTextFinderAction(tag: Int) {
        let item = NSMenuItem()
        item.tag = tag
        performTextFinderAction(item)
    }

    // MARK: - Context menu

    /// Gate the system context-menu plug-ins (Writing Tools, Summarize,
    /// Services, AutoFill) on there being a selection.
    ///
    /// Those items are injected by AppKit *at display time*, after `menu(for:)`
    /// returns, and are all governed by `allowsContextMenuPlugIns`. With an
    /// empty selection, Writing Tools runs against the WHOLE markup document —
    /// which stalls for a long time and then fails. Restricting the plug-ins to
    /// a non-empty selection keeps Writing Tools bounded (and fast), while the
    /// cell brackets provide an explicit, always-bounded entry point.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        let selection = selectedRange()
        menu.allowsContextMenuPlugIns = selection.length > 0
        // Offer the configurable AI author-tasks as a flat "AI Assist" section on
        // a non-empty selection — the same tasks (and shortcuts) the cell
        // brackets provide, bounded to the selected range.
        if selection.length > 0 {
            InlineAITaskCatalog.appendSection(to: menu, tasks: aiTasks, range: selection,
                                              target: self, action: #selector(runSelectionAITask(_:)))
        }
        return menu
    }

    /// Curated AI tasks for the selection context menu + the handler, both set
    /// by the coordinator (mirrors the bracket ruler).
    var aiTasks: [AITaskDescriptor] = []
    var aiRequestHandler: ((_ actionId: String, _ range: NSRange) -> Void)?

    @objc private func runSelectionAITask(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? AITaskMenuPayload else { return }
        aiRequestHandler?(payload.actionId, payload.range)
    }

    /// The range an AI keyboard shortcut acts on: the selection if any, else the
    /// blank-line-delimited paragraph containing the caret.
    private func aiTargetRange() -> NSRange {
        let sel = selectedRange()
        if sel.length > 0 { return sel }
        let ns = string as NSString
        let len = ns.length
        guard len > 0 else { return NSRange(location: 0, length: 0) }
        let caret = min(max(0, sel.location), len)
        // Walk back to the start of the paragraph (after a blank line / doc start).
        var start = min(caret, len - 1)
        while start > 0 {
            if ns.character(at: start - 1) == 10,
               start - 1 == 0 || ns.character(at: start - 2) == 10 { break }
            start -= 1
        }
        // Walk forward to the end of the paragraph (before a blank line / doc end).
        var end = caret
        while end < len {
            if ns.character(at: end) == 10,
               end + 1 >= len || ns.character(at: end + 1) == 10 { break }
            end += 1
        }
        return NSRange(location: start, length: max(0, end - start))
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

/// Menu payload: an AI task's action id + the source range it targets. Shared
/// by the cell-bracket menu and the text-selection menu.
final class AITaskMenuPayload: NSObject {
    let actionId: String
    let range: NSRange
    init(actionId: String, range: NSRange) {
        self.actionId = actionId
        self.range = range
    }
}

/// A curated AI task ready to render in a context menu (resolved title/icon +
/// its keyboard shortcut). Plain value type so AppKit menu code can use it off
/// the main-actor-isolated services.
struct AITaskDescriptor {
    let id: String
    let title: String
    let icon: String
    let key: String
    let modifiers: NSEvent.ModifierFlags
}

/// Curated author tasks surfaced as a flat "AI Assist" section in the bracket +
/// selection context menus, each bound to a keyboard shortcut. The ⌃⌘<letter>
/// grammar is the shared impress-suite convention for AI assistance — the same
/// keys should map to the same intent across imbib/imprint/impart/etc.
enum InlineAITaskCatalog {
    struct Curated {
        let id: String
        let key: String                    // key-equivalent letter (lowercased)
        let modifiers: NSEvent.ModifierFlags
    }

    /// Shared AI shortcut modifier for the whole suite: Control+Command.
    static let modifier: NSEvent.ModifierFlags = [.command, .control]

    /// Curated tasks in menu order, each bound to ⌃⌘<letter>.
    static let curated: [Curated] = [
        Curated(id: "rewrite.improve_clarity",     key: "c", modifiers: modifier), // Clarity
        Curated(id: "rewrite.make_concise",        key: "s", modifiers: modifier), // Shorten
        Curated(id: "rewrite.expand_detail",       key: "e", modifiers: modifier), // Expand
        Curated(id: "structure.integrate",         key: "i", modifiers: modifier), // Integrate
        Curated(id: "review.suggest_improvements", key: "r", modifiers: modifier), // Review
        Curated(id: "citations.find_supporting",   key: "k", modifiers: modifier), // Cite
    ]

    /// Enabled tasks resolved to display metadata + shortcut (main-actor: reads
    /// the host's live task set + preferences via `ManuscriptEditorEnvironment`).
    @MainActor
    static func tasks() -> [AITaskDescriptor] {
        let env = ManuscriptEditorEnvironment.shared
        return curated.compactMap { c in
            guard env.isAITaskEnabled(c.id),
                  let meta = env.aiTaskMetadata(c.id) else { return nil }
            return AITaskDescriptor(id: c.id, title: meta.title, icon: meta.icon,
                                    key: c.key, modifiers: c.modifiers)
        }
    }

    /// The enabled action id bound to a key-equivalent, for editor keyboard
    /// handling. Reads the host's enablement predicate.
    @MainActor
    static func actionID(forKey key: String, modifiers: NSEvent.ModifierFlags) -> String? {
        let mods = modifiers.intersection([.command, .control, .option, .shift])
        guard let c = curated.first(where: { $0.key == key.lowercased() && $0.modifiers == mods }) else { return nil }
        return ManuscriptEditorEnvironment.shared.isAITaskEnabled(c.id) ? c.id : nil
    }

    /// Append a flat "AI Assist" section (header + task items with visible
    /// shortcuts) to `menu` from already-resolved `tasks`. Items target
    /// `target`/`action`, each carrying an `AITaskMenuPayload` for `range`.
    static func appendSection(to menu: NSMenu, tasks: [AITaskDescriptor], range: NSRange,
                              target: AnyObject, action: Selector) {
        guard !tasks.isEmpty else { return }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "AI Assist"))
        for t in tasks {
            let item = menu.addItem(withTitle: t.title, action: action, keyEquivalent: t.key)
            item.keyEquivalentModifierMask = t.modifiers
            item.target = target
            item.image = NSImage(systemSymbolName: t.icon, accessibilityDescription: nil)
            item.representedObject = AITaskMenuPayload(actionId: t.id, range: range)
        }
    }

    @MainActor
    static func post(actionId: String, range: NSRange) {
        Logger.editor.infoCapture("InlineAITask post: \(actionId) range=\(range.location),\(range.length)", category: "ai")
        // Host-provided sink (imprint posts `.runInlineAITask`; no-op by default).
        ManuscriptEditorEnvironment.shared.onAITaskRequested(actionId, range)
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
#endif // os(macOS)
