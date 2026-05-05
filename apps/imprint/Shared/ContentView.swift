#if os(macOS)
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import ImpressGit
import ImpressLogging
import OSLog
import ImprintCore
import ImpressKeyboard
import ImpressKit
import ImpressOperationQueue
import ImpressPublicationUI

/// Main content view for an imprint document (macOS)
struct ContentView: View {
    @Binding var document: ImprintDocument
    @Environment(AppState.self) private var appState

    @State private var cursorPosition: Int = 0
    @State private var pdfData: Data?
    @State private var sourceMapEntries: [SourceMapEntry] = []
    @State private var isCompiling = false
    @State private var compilationError: String?
    @State private var compilationWarnings: [String] = []
    @State private var debugStatus: String = "idle"
    @State private var debugHistory: String = ""

    // SVG preview state
    @State private var svgPages: [String] = []

    // In-imprint paper detail panel — publication ID if open, nil otherwise
    @State private var openPaperPublicationID: String?

    // Suppress auto-compile while the inline citation palette is open — typing
    // an incomplete `\cite{` produces a compile error otherwise.
    @State private var citationPaletteOpen: Bool = false

    // Auto-compile (Typst)
    @AppStorage("imprint.autoCompile") private var autoCompileEnabled = true
    @AppStorage("imprint.compileDebounceMs") private var compileDebounceMs = 300
    @AppStorage("imprint.previewFormat") private var previewFormat = "pdf"
    @State private var autoCompileTask: Task<Void, Never>?
    @State private var forwardSyncTask: Task<Void, Never>?

    // LaTeX-specific state
    @AppStorage("imprint.latex.defaultEngine") private var latexDefaultEngine = "pdflatex"
    @AppStorage("imprint.latex.autoCompile") private var latexAutoCompileEnabled = true
    @AppStorage("imprint.latex.compileDebounceMs") private var latexCompileDebounceMs = 1500
    @AppStorage("imprint.latex.shellEscape") private var latexShellEscape = false
    @AppStorage("imprint.latex.showBoxWarnings") private var latexShowBoxWarnings = false
    @State private var latexDiagnostics: [LaTeXDiagnostic] = []
    @State private var latexCompilationTimeMs: Int = 0
    @State private var syncTeXHighlight: SyncTeXPosition?
    @State private var showingSymbolPalette = false
    @State private var latexProjectFiles: [URL] = []
    @State private var latexMainFileURL: URL?
    @State private var postCompileTask: Task<Void, Never>?

    // AI Context Menu state
    @State private var showingAIContextMenu = false
    @State private var currentSuggestion: RewriteSuggestion?
    @State private var aiErrorMessage: String?

    #if os(macOS)
    /// Comment service for this document (macOS only)
    @State private var commentService = CommentService()
    #endif

    /// Shared Typst renderer instance
    private let renderer = TypstRenderer()

    /// Owns the external-candidate picker state. Lifted out of the
    /// sidebar's `CitedPapersSection` (where the sheet used to live) so
    /// that Section body re-evals don't interrupt the sheet's
    /// presentation/dismissal animations. `.sheet(item:)` is attached to
    /// `mainContent` below alongside the app's other sheets.
    @State private var citationPicker = CitationPickerCoordinator()

    var body: some View {
        @Bindable var appState = appState

        ZStack {
            mainContent

            // Focus Mode overlay
            if appState.isFocusMode {
                FocusModeView(
                    source: $document.source,
                    cursorPosition: $cursorPosition,
                    isActive: $appState.isFocusMode,
                    syntaxMode: appState.documentFormat
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.isFocusMode)
        .wireUndo(to: ImprintUndoCoordinator.shared)
    }

    @ViewBuilder
    private var mainContent: some View {
        @Bindable var appState = appState

        // All three modes: sidebar on the left, mode-specific content on the right.
        // Single HSplitView — no nesting.
        HSplitView {
            outlineSidebar

            switch appState.editMode {
            case .textOnly:
                SourceEditorView(
                    source: $document.source,
                    cursorPosition: $cursorPosition,
                    syntaxMode: appState.documentFormat,
                    onSelectionChange: { selectedText, selectedRange in
                        appState.selectedText = selectedText
                        appState.selectedRange = selectedRange
                    }
                )

            case .splitView:
                // Editor + PDF side by side. HSplitView gives native
                // macOS drag-to-resize with correct cursor and smooth
                // tracking. The CLAUDE.md HSplitView warning applies to
                // HSplitView nested inside NavigationSplitView detail
                // panes (toolbar positioning), not to standalone use.
                HSplitView {
                    VStack(spacing: 0) {
                        SourceEditorView(
                            source: $document.source,
                            cursorPosition: $cursorPosition,
                            syntaxMode: appState.documentFormat,
                            onSelectionChange: { selectedText, selectedRange in
                                appState.selectedText = selectedText
                                appState.selectedRange = selectedRange
                            }
                        )
                        .frame(maxHeight: .infinity)

                        CompilationErrorView(
                            diagnostics: latexDiagnostics,
                            errors: compilationError,
                            warnings: compilationWarnings,
                            onNavigateToLine: { line in navigateToLine(line) }
                        )
                    }
                    .frame(minWidth: 250, idealWidth: 500)

                    PDFPreviewView(
                        pdfData: pdfData,
                        isCompiling: isCompiling,
                        sourceMapEntries: sourceMapEntries,
                        cursorPosition: cursorPosition,
                        onInverseSync: appState.documentFormat == .latex ? { _, line, _ in
                            navigateToLine(line)
                        } : nil,
                        syncTeXHighlight: syncTeXHighlight
                    )
                    .frame(minWidth: 250, idealWidth: 500)
                }

            case .directPdf:
                DirectPDFView(
                    document: $document,
                    pdfData: pdfData,
                    sourceMapEntries: sourceMapEntries,
                    cursorPosition: $cursorPosition
                )
            }

            // Right-side paper detail panel (Track E). Opens via cite-key action,
            // floats over the detail area with a fixed width.
            if let pubID = openPaperPublicationID {
                PaperDetailPanel(
                    publicationID: pubID,
                    dataSource: ImprintPublicationService.shared,
                    onClose: { openPaperPublicationID = nil }
                )
                .frame(width: 420)
                .background(.regularMaterial)
            }
        }
        .onChange(of: appState.editMode) { _, _ in
            // When switching modes, scroll the new views to the current position.
            // Bump cursorPosition to force the editor to re-scroll, then trigger SyncTeX.
            let pos = cursorPosition
            Task { @MainActor in
                // Brief delay to let new views appear
                try? await Task.sleep(for: .milliseconds(150))
                // Toggle cursorPosition to force onChange to fire
                cursorPosition = pos + 1
                try? await Task.sleep(for: .milliseconds(50))
                cursorPosition = pos
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Edit mode picker - custom segmented control for accessibility
                EditModeSegmentedControl(selection: $appState.editMode)
                    .accessibilityIdentifier("toolbar.editModePicker")

                Spacer()

                // Format indicator (LaTeX mode)
                if appState.documentFormat == .latex {
                    Text("LaTeX")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)

                    // Engine picker
                    Picker("Engine", selection: $latexDefaultEngine) {
                        ForEach(LaTeXEngine.allCases, id: \.rawValue) { engine in
                            Text(engine.displayName).tag(engine.rawValue)
                        }
                    }
                    .frame(width: 110)
                    .accessibilityIdentifier("toolbar.enginePicker")
                }

                // Compile button
                Button {
                    Task { await compile() }
                } label: {
                    if isCompiling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "hammer")
                    }
                }
                .help("Refresh Preview (\u{2318}\u{21A9})")
                .keyboardShortcut(.return, modifiers: [.command])
                .accessibilityIdentifier("toolbar.compileButton")

                // Citation button
                Button {
                    appState.showingCitationPicker = true
                } label: {
                    Image(systemName: "quote.opening")
                }
                .help("Insert Citation (Cmd+Shift+K)")
                .accessibilityIdentifier("toolbar.citationButton")

                // AI Assistant button
                Button {
                    withAnimation {
                        appState.showingAIAssistant.toggle()
                    }
                } label: {
                    Image(systemName: appState.showingAIAssistant ? "sparkles.rectangle.stack.fill" : "sparkles")
                }
                .help("AI Assistant (Cmd+.)")
                .accessibilityIdentifier("toolbar.aiAssistantButton")

                // Comments button
                Button {
                    withAnimation {
                        appState.showingComments.toggle()
                    }
                } label: {
                    Image(systemName: appState.showingComments ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                }
                .help("Comments (Cmd+Opt+K)")
                .accessibilityIdentifier("toolbar.commentsButton")

                // Git status badge
                #if os(macOS)
                GitStatusBadge(
                    status: ImprintGitIntegration.shared.repoStatus,
                    isSyncing: ImprintGitIntegration.shared.isSyncing
                ) {
                    ImprintGitIntegration.shared.handleCommit()
                }
                #endif

                // Collaborator avatars
                #if os(macOS)
                CollaboratorAvatarsView()
                #endif

                // Debug status (only in debug builds)
                #if DEBUG
                Text("pdf=\(pdfData?.count ?? 0)b")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("debug.pdfSize")
                Text(debugHistory)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("debug.history")
                Text("err=\(compilationError?.prefix(100) ?? "none")")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .accessibilityIdentifier("debug.error")
                #endif
            }
        }
        .sheet(isPresented: $appState.showingCitationPicker) {
            CitationPickerView(document: $document, cursorPosition: cursorPosition)
        }
        .sheet(isPresented: $appState.showingVersionHistory) {
            VersionHistoryView(document: $document)
        }
        .modifier(NotificationHandlersModifier(
            appState: appState,
            onCompile: { Task { await compile() } },
            onExportPDF: { exportPDF() },
            onPrintPDF: { printPDF() },
            onShowSymbolPalette: { showingSymbolPalette = true }
        ))
        .sheet(isPresented: $showingSymbolPalette) {
            LaTeXSymbolPalette(isPresented: $showingSymbolPalette) { symbol in
                insertTextAtCursor(symbol)
            }
        }
        // Git integration (sheets + notification handlers extracted to modifier)
        #if os(macOS)
        .modifier(GitIntegrationModifier())
        #endif
        .task {
            // Detect document format and propagate to AppState
            appState.documentFormat = document.format
            // Register this document's comment service so the HTTP API can
            // list/create/resolve comments for it from agent workflows.
            CommentRegistry.shared.register(commentService, for: document.id)
            // Tell the outline snapshot maintainer which document's
            // stored structure to track. When the document has ≥2
            // sections, `DocumentOutlineView` reads from the snapshot
            // instead of re-parsing `document.source` with regex.
            let capturedID = document.id
            Task.detached(priority: .utility) {
                await OutlineSnapshotMaintainer.shared.setFocusedDocument(capturedID)
            }
            // Project the bibliography on first open so the .bib is always fresh.
            // Writes to the same temp compile dir as the .tex so biber can find it.
            let bibURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("imprint-latex-\(document.id.uuidString)")
                .appendingPathComponent("main.bib")
            let src = document.source
            let bib = document.bibliography
            Task {
                await BibliographyProjector.shared.scheduleUpdate(source: src, bibFileURL: bibURL, bibliography: bib)
            }
            await compile()
        }
        .onChange(of: document.source) { _, newSource in
            scheduleAutoCompile()
            // Sync to the shared impress-core store so agents and sibling apps
            // can query the latest section content via `manuscript-section@1.0.0`.
            // Capture document properties before entering the Task to avoid stale
            // @Binding reads (CLAUDE.md: "Capture @State Before Async Work").
            let capturedTitle = document.title
            let capturedDocID = document.id.uuidString
            Task { @MainActor in
                ImprintStoreAdapter.shared.storeSection(
                    sectionID: capturedDocID,
                    title: capturedTitle.isEmpty ? "Untitled" : capturedTitle,
                    body: newSource,
                    sectionType: nil,
                    orderIndex: 0,
                    documentID: capturedDocID
                )
            }

            // Live bibliography file projection: regenerate `main.bib` in the same
            // temp compilation directory that pdflatex uses, so biber/bibtex can
            // pick it up automatically. Sandbox-friendly (temp dir is writable).
            let bibURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("imprint-latex-\(document.id.uuidString)")
                .appendingPathComponent("main.bib")
            let capturedBibliography = document.bibliography
            Task {
                await BibliographyProjector.shared.scheduleUpdate(
                    source: newSource,
                    bibFileURL: bibURL,
                    bibliography: capturedBibliography
                )
            }
        }
        .onChange(of: cursorPosition) { _, newPosition in
            // Forward SyncTeX: cursor → PDF highlight (LaTeX mode only, debounced)
            guard appState.documentFormat == .latex else { return }
            forwardSyncTask?.cancel()
            let source = document.source
            let fileName = latexMainFileURL?.lastPathComponent ?? document.title + ".tex"
            forwardSyncTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                // Convert cursor offset to line number
                let prefix = source.prefix(min(newPosition, source.count))
                let line = prefix.filter { $0 == "\n" }.count + 1
                logInfo("Forward SyncTeX: file=\(fileName), line=\(line), offset=\(newPosition)", category: "synctex")
                // Try the actual filename first, fall back to main.tex
                var positions = await SyncTeXService.shared.forwardSync(file: fileName, line: line, column: 0)
                if positions.isEmpty {
                    positions = await SyncTeXService.shared.forwardSync(file: "main.tex", line: line, column: 0)
                }
                logInfo("Forward SyncTeX result: \(positions.count) positions", category: "synctex")
                // Pick the topmost, leftmost position (top of page = largest y in SyncTeX coords)
                let best = positions.max(by: { a, b in
                    if a.page != b.page { return a.page > b.page }
                    if abs(a.y - b.y) > 10 { return a.y > b.y } // higher on page = smaller SyncTeX y
                    return a.x > b.x // leftmost
                })
                if let first = best {
                    await MainActor.run {
                        syncTeXHighlight = first
                        // Scroll PDF directly — HSplitView blocks SwiftUI onChange propagation
                        scrollPDFToSyncTeX(first)
                    }
                }
            }
        }
        // HTTP API automation handlers (applied before platform-specific handlers)
        .modifier(AutomationHandlersModifier(document: $document))
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .openPaperPanel)) { notification in
            if let pubID = notification.userInfo?["publicationID"] as? String {
                openPaperPublicationID = pubID
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inlineCitationPaletteOpened)) { _ in
            citationPaletteOpen = true
            // Cancel any pending auto-compile so an incomplete `\cite{` doesn't fire one
            autoCompileTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .inlineCitationPaletteClosed)) { _ in
            citationPaletteOpen = false
            // Re-fire any compile we suppressed while the palette was open.
            // The source has either: not changed (escape) — compile is fast no-op,
            // or changed by a citation insert — this catches the missed compile.
            scheduleAutoCompile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .inlineCitationInserted)) { notification in
            // Track A → Track B: when the inline palette inserts a citation, add that
            // paper to the manuscript-local imbib library (creating it if needed).
            guard let userInfo = notification.userInfo,
                  let publicationID = userInfo["publicationID"] as? String else { return }
            Task { @MainActor in
                ManuscriptLibraryCoordinator.shared.addPublication(publicationID: publicationID, to: &document)
                // Also fetch the raw BibTeX and add to the document's bibliography dict
                // so it gets written out by Track C on the next debounce.
                if let detail = ImprintPublicationService.shared.detail(id: publicationID),
                   let bibtex = detail.rawBibtex, !bibtex.isEmpty,
                   let citeKey = userInfo["citeKey"] as? String {
                    document.addCitation(key: citeKey, bibtex: bibtex)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .addCommentAtSelection)) { _ in
            // Add comment at current selection
            if let range = appState.selectedRange, range.length > 0 {
                let textRange = TextRange(nsRange: range)
                commentService.addComment(
                    content: "",
                    at: textRange
                )
                appState.showingComments = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAIContextMenu)) { _ in
            // Show AI context menu (Cmd+Shift+A)
            showingAIContextMenu = true
        }
        .sheet(isPresented: $showingAIContextMenu) {
            AIContextMenuContent(
                selectedText: $appState.selectedText,
                selectedRange: $appState.selectedRange,
                documentSource: document.source,
                onActionResult: { suggestion in
                    currentSuggestion = suggestion
                    showingAIContextMenu = false
                },
                onDismiss: {
                    showingAIContextMenu = false
                },
                onError: { error in
                    aiErrorMessage = error
                }
            )
            .frame(width: 300, height: 500)
        }
        .sheet(item: $currentSuggestion) { suggestion in
            RewriteSuggestionView(
                suggestion: suggestion,
                onAccept: { text in
                    replaceSelection(with: text)
                    currentSuggestion = nil
                },
                onReject: {
                    currentSuggestion = nil
                },
                onEdit: {
                    // Open in AI chat sidebar with the suggestion
                    appState.showingAIAssistant = true
                    currentSuggestion = nil
                },
                onCancel: suggestion.isStreaming ? {
                    AIContextMenuService.shared.cancelCurrentAction()
                    currentSuggestion = nil
                } : nil
            )
        }
        // External-candidate picker for "import missing cite key" flow.
        // Attached here (at `mainContent` level) rather than inside the
        // sidebar List Section — SwiftUI-on-macOS flickers sheets whose
        // presenter re-evaluates during the dismiss animation.
        .sheet(item: Binding(
            get: { citationPicker.candidateSheet },
            set: { citationPicker.candidateSheet = $0 }
        )) { sheet in
            ExternalCitationPicker(
                paper: sheet.paper,
                candidates: sheet.candidates,
                onPick: { candidate in
                    // Picker calls `dismiss()` before invoking this closure;
                    // we delay the heavy import work slightly so the sheet
                    // dismiss animation completes before coordinator state
                    // mutations trigger any re-renders.
                    let dest = sheet.destination
                    let p = sheet.paper
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        await citationPicker.importPicked(candidate, for: p, destination: dest)
                    }
                }
            )
        }
        .environment(citationPicker)
        .alert("AI Error", isPresented: Binding(
            get: { aiErrorMessage != nil },
            set: { if !$0 { aiErrorMessage = nil } }
        )) {
            Button("OK") {
                aiErrorMessage = nil
            }
        } message: {
            Text(aiErrorMessage ?? "An unknown error occurred.")
        }
        #endif
    }

    /// Sidebar with outline, project files, and cited papers.
    private var outlineSidebar: some View {
        List {
            DocumentOutlineView(
                source: document.source,
                format: appState.documentFormat,
                documentID: document.id,
                onNavigateToLine: { line in navigateToLine(line) }
            )
            .accessibilityIdentifier("sidebar.outline")

            if appState.documentFormat == .latex && !latexProjectFiles.isEmpty {
                LaTeXProjectSidebarView(
                    projectFiles: latexProjectFiles,
                    mainFileURL: latexMainFileURL,
                    onSelectFile: { _ in }
                )
            }

            #if os(macOS)
            CitedPapersSection(
                source: document.source,
                documentTitle: document.title,
                bibliography: document.bibliography
            )
            #endif
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
        .focusable()
        .focusEffectDisabled()
        .keyboardGuarded { press in
            handleVimNavigation(press)
        }
    }

    @ViewBuilder
    private var editorView: some View {
        @Bindable var appState = appState

        HStack(spacing: 0) {
            // Comments sidebar (left)
            if appState.showingComments {
                #if os(macOS)
                CommentsSidebarView(
                    commentService: commentService,
                    onNavigateToRange: { range in
                        cursorPosition = range.start
                    }
                )
                .transition(.move(edge: .leading))

                Divider()
                #endif
            }

            // Main editor content
            mainEditorContent
                .frame(maxWidth: .infinity)

            // AI Assistant sidebar (right)
            if appState.showingAIAssistant {
                Divider()

                #if os(macOS)
                AIChatSidebar(
                    selectedText: $appState.selectedText,
                    documentSource: $document.source,
                    onInsertText: { text in
                        insertTextAtCursor(text)
                    }
                )
                .transition(.move(edge: .trailing))
                #endif
            }
        }
    }

    @ViewBuilder
    private var mainEditorContent: some View {
        switch appState.editMode {
        case .directPdf:
            DirectPDFView(
                document: $document,
                pdfData: pdfData,
                sourceMapEntries: sourceMapEntries,
                cursorPosition: $cursorPosition
            )

        case .splitView:
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    // Gutter with line numbers and diagnostics
                    if !latexDiagnostics.isEmpty || appState.documentFormat == .latex {
                        EditorGutterView(
                            lineCount: document.source.reduce(1) { count, char in char == "\n" ? count + 1 : count },
                            diagnosticsByLine: EditorGutterView.diagnosticsMap(from: latexDiagnostics),
                            onTapLine: { line in navigateToLine(line) }
                        )
                    }

                    SourceEditorView(
                        source: $document.source,
                        cursorPosition: $cursorPosition,
                        syntaxMode: appState.documentFormat,
                        onSelectionChange: { selectedText, selectedRange in
                            appState.selectedText = selectedText
                            appState.selectedRange = selectedRange
                        }
                    )
                }
                .frame(minWidth: 300, maxHeight: .infinity)

                Divider()

                VStack(spacing: 0) {
                    if previewFormat == "svg" && !svgPages.isEmpty && appState.documentFormat == .typst {
                        SVGPreviewView(
                            svgPages: svgPages,
                            isCompiling: isCompiling,
                            sourceMapEntries: sourceMapEntries,
                            cursorPosition: cursorPosition
                        )
                        .frame(maxHeight: .infinity)
                    } else {
                        PDFPreviewView(
                            pdfData: pdfData,
                            isCompiling: isCompiling,
                            sourceMapEntries: sourceMapEntries,
                            cursorPosition: cursorPosition,
                            onInverseSync: appState.documentFormat == .latex ? { _, line, _ in
                                navigateToLine(line)
                            } : nil,
                            syncTeXHighlight: syncTeXHighlight
                        )
                        .frame(maxHeight: .infinity)
                    }

                    CompilationErrorView(
                        diagnostics: latexDiagnostics,
                        errors: compilationError,
                        warnings: compilationWarnings,
                        onNavigateToLine: { line in
                            navigateToLine(line)
                        }
                    )
                }
                .frame(minWidth: 300, maxHeight: .infinity)
            }

        case .textOnly:
            SourceEditorView(
                source: $document.source,
                cursorPosition: $cursorPosition,
                syntaxMode: appState.documentFormat,
                onSelectionChange: { selectedText, selectedRange in
                    appState.selectedText = selectedText
                    appState.selectedRange = selectedRange
                }
            )
        }
    }

    // MARK: - Vim Navigation

    /// Handle vim-style navigation keys (h/j/k/l)
    private func handleVimNavigation(_ press: KeyPress) -> KeyPress.Result {
        // Text field guarding is handled by .keyboardGuarded at the call site
        switch press.characters.lowercased() {
        case "j":
            // Navigate down in outline
            // For now, just a placeholder - outline navigation would need state
            return .ignored
        case "k":
            // Navigate up in outline
            return .ignored
        case "h":
            // Go back / collapse
            return .ignored
        case "l":
            // Go forward / expand / open
            return .ignored
        default:
            return .ignored
        }
    }

    /// Insert text at the current cursor position
    private func insertTextAtCursor(_ text: String) {
        let position = min(cursorPosition, document.source.count)
        let index = document.source.index(document.source.startIndex, offsetBy: position)
        document.source.insert(contentsOf: text, at: index)
        cursorPosition = position + text.count
    }

    /// Replace the current selection with new text
    private func replaceSelection(with text: String) {
        guard let range = appState.selectedRange,
              let swiftRange = Range(range, in: document.source) else {
            // No selection, insert at cursor
            insertTextAtCursor(text)
            return
        }

        document.source.replaceSubrange(swiftRange, with: text)
        cursorPosition = range.location + text.count

        // Clear selection
        appState.selectedText = ""
        appState.selectedRange = NSRange(location: cursorPosition, length: 0)
    }

    // MARK: - Auto-Compile

    /// Schedule a debounced auto-compile after a typing pause.
    /// Uses format-specific debounce — LaTeX is heavier so defaults to 1500ms.
    private func scheduleAutoCompile() {
        let isAutoEnabled: Bool
        let delayMs: Int

        switch appState.documentFormat {
        case .typst:
            isAutoEnabled = autoCompileEnabled
            delayMs = compileDebounceMs
        case .latex:
            isAutoEnabled = latexAutoCompileEnabled
            delayMs = latexCompileDebounceMs
        }

        guard isAutoEnabled else { return }
        // Skip auto-compile while the user is searching for a citation OR if the
        // source contains an unclosed `\cite{...}` near the cursor — both would
        // just produce a compile error. The unclosed-brace check is the reliable
        // signal; the palette flag is best-effort and can race with notifications.
        guard !citationPaletteOpen else { return }
        if appState.documentFormat == .latex,
           hasUnclosedCiteBrace(in: document.source, near: cursorPosition) {
            return
        }
        autoCompileTask?.cancel()
        autoCompileTask = Task {
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
            // Re-check at fire time
            if citationPaletteOpen { return }
            if appState.documentFormat == .latex,
               hasUnclosedCiteBrace(in: document.source, near: cursorPosition) {
                return
            }
            await compile()
        }
    }

    /// Returns true if the cursor is currently inside an unclosed `\cite*{...`
    /// — the source isn't compilable in that state, so auto-compile would error.
    private func hasUnclosedCiteBrace(in source: String, near location: Int) -> Bool {
        let ns = source as NSString
        let safe = max(0, min(location, ns.length))
        // Scan back up to 200 chars for an open `{` that belongs to a cite command,
        // bailing if we hit `}`, newline, or another `{` (not preceded by `\cite*`).
        var i = safe - 1
        let limit = max(0, safe - 200)
        while i >= limit {
            let ch = ns.character(at: i)
            if ch == 125 /* } */ || ch == 10 /* \n */ { return false }
            if ch == 123 /* { */ {
                // Walk backwards over command name letters / `*`
                var j = i - 1
                while j >= 0 {
                    let cu = ns.character(at: j)
                    let isLetter = (cu >= 65 && cu <= 90) || (cu >= 97 && cu <= 122)
                    if isLetter || cu == 42 { j -= 1 } else { break }
                }
                guard j >= 0, ns.character(at: j) == 92 /* \ */ else { return false }
                let name = ns.substring(with: NSRange(location: j + 1, length: i - (j + 1))).lowercased()
                let isCite = name.hasPrefix("cite")
                    || name.hasPrefix("parencite")
                    || name.hasPrefix("textcite")
                    || name.hasPrefix("autocite")
                    || name.hasPrefix("footcite")
                    || name.hasPrefix("smartcite")
                    || name.hasPrefix("supercite")
                    || name.hasPrefix("nocite")
                return isCite
            }
            i -= 1
        }
        return false
    }

    // MARK: - Navigation

    /// Scroll the PDF view to a SyncTeX position.
    /// Finds the live PDFView by walking the key window's view hierarchy.
    private func scrollPDFToSyncTeX(_ position: SyncTeXPosition) {
        guard let pdfView = findLivePDFView() else {
            logInfo("scrollPDFToSyncTeX: no live PDFView found in window", category: "synctex")
            return
        }
        guard let document = pdfView.document else { return }

        let pageIndex = position.page - 1
        guard pageIndex >= 0, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { return }

        let pageBounds = page.bounds(for: .mediaBox)
        // SyncTeX y is from top of page; PDF coordinates are from bottom.
        // Offset upward by ~30pt to show the section heading above the first SyncTeX node.
        let pdfY = min(pageBounds.height, pageBounds.height - position.y + 30)

        let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: pdfY))
        pdfView.go(to: destination)

        logInfo("Scrolled PDF to page \(position.page), pdfY=\(Int(pdfY))", category: "synctex")
    }

    /// Walk the view hierarchy to find the actual live PDFView.
    private func findLivePDFView() -> PDFView? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        return findPDFView(in: window.contentView)
    }

    private func findPDFView(in view: NSView?) -> PDFView? {
        guard let view = view else { return nil }
        if let pdfView = view as? PDFView { return pdfView }
        for subview in view.subviews {
            if let found = findPDFView(in: subview) { return found }
        }
        return nil
    }

    /// Navigate cursor to a specific line number in source.
    private func navigateToLine(_ lineNumber: Int) {
        let lines = document.source.components(separatedBy: "\n")
        var offset = 0
        for i in 0..<min(lineNumber - 1, lines.count) {
            offset += lines[i].count + 1 // +1 for newline
        }
        cursorPosition = offset
    }

    // MARK: - Export

    /// Print compiled PDF via system print dialog.
    private func printPDF() {
        guard let data = pdfData, !data.isEmpty else {
            // No PDF yet — compile first, then print.
            // Capture pdfData after compile returns (still on MainActor).
            Task { @MainActor in
                await compile()
                // Re-read @State after compile has set it
                guard let data = self.pdfData, !data.isEmpty else { return }
                showPrintDialog(data)
            }
            return
        }
        showPrintDialog(data)
    }

    private func showPrintDialog(_ data: Data) {
        guard let pdfDocument = PDFKit.PDFDocument(data: data) else { return }
        let printInfo = NSPrintInfo.shared
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = false

        let printOperation = pdfDocument.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true)
        printOperation?.showsPrintPanel = true
        printOperation?.showsProgressPanel = true
        printOperation?.run()
    }

    /// Export compiled PDF via NSSavePanel.
    private func exportPDF() {
        guard let data = pdfData, !data.isEmpty else {
            // No PDF yet — compile first, then export.
            Task { @MainActor in
                await compile()
                guard let data = self.pdfData, !data.isEmpty else { return }
                savePDFData(data)
            }
            return
        }
        savePDFData(data)
    }

    private func savePDFData(_ data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(document.title.isEmpty ? "Untitled" : document.title).pdf"
        panel.canCreateDirectories = true

        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try data.write(to: url)
                    log("Exported PDF to \(url.path)")
                } catch {
                    log("Export failed: \(error)")
                }
            }
        }
    }

    // MARK: - Compilation

    private func log(_ message: String) {
        Logger.compilation.infoCapture(message, category: "compile")
    }

    private func compile() async {
        let sourceLen = document.source.count
        let format = appState.documentFormat
        Logger.compilation.infoCapture("Compile started: format=\(format), source=\(sourceLen)ch", category: "compile")
        log("compile() started")
        debugHistory = ""
        debugStatus = "1:started"
        debugHistory += "1 "
        isCompiling = true
        compilationError = nil
        compilationWarnings = []
        latexDiagnostics = []

        // Branch on document format
        switch appState.documentFormat {
        case .typst:
            await compileTypst()
        case .latex:
            await compileLaTeX()
        }

        isCompiling = false
        debugStatus = "F:pdf=\(pdfData?.count ?? 0)"
        debugHistory += "F:\(pdfData?.count ?? 0)"
        Logger.compilation.infoCapture("Compile finished: pdf=\(pdfData?.count ?? 0)b, errors=\(compilationError != nil ? 1 : 0)", category: "compile")
        log("compile() finished")
    }

    // MARK: - Typst Compilation

    private func compileTypst() async {
        let sourceText = document.source
        let format = previewFormat
        debugStatus = "2:src=\(sourceText.count)ch"
        debugHistory += "2:\(sourceText.count) "
        log("Source text length: \(sourceText.count), format: \(format)")

        do {
            log("Creating RenderOptions")
            debugStatus = "3:options"
            debugHistory += "3 "
            let options = RenderOptions(
                pageSize: .a4,
                isDraft: false
            )

            if format == "svg" {
                debugStatus = "4:rendering(svg)"
                debugHistory += "4svg "
                log("Calling renderer.renderSVG()")
                let output = try await renderer.renderSVG(sourceText, options: options)
                debugStatus = "5:done,ok=\(output.isSuccess),pages=\(output.svgPages.count)"
                debugHistory += "5:\(output.svgPages.count)p "

                if output.isSuccess {
                    svgPages = output.svgPages
                    sourceMapEntries = output.sourceMapEntries
                    compilationWarnings = output.warnings

                    let pdfOutput = try await renderer.render(sourceText, options: options)
                    if pdfOutput.isSuccess {
                        pdfData = pdfOutput.pdfData
                        DocumentRegistry.shared.cachePDF(pdfOutput.pdfData, for: document.id)
                    }

                    debugStatus = "6:set,\(output.svgPages.count)p,map=\(output.sourceMapEntries.count)"
                    debugHistory += "6:ok "
                } else {
                    compilationError = output.errors.joined(separator: "\n")
                    debugHistory += "E "
                }
            } else {
                debugStatus = "4:rendering(pdf)"
                debugHistory += "4pdf "
                let output = try await renderer.render(sourceText, options: options)
                debugStatus = "5:done,ok=\(output.isSuccess),sz=\(output.pdfData.count)"
                debugHistory += "5:\(output.pdfData.count) "

                if output.isSuccess {
                    pdfData = output.pdfData
                    sourceMapEntries = output.sourceMapEntries
                    compilationWarnings = output.warnings
                    DocumentRegistry.shared.cachePDF(output.pdfData, for: document.id)
                    debugStatus = "6:set,\(output.pdfData.count)b,map=\(output.sourceMapEntries.count)"
                    debugHistory += "6:ok "
                } else {
                    compilationError = output.errors.joined(separator: "\n")
                    debugHistory += "E "
                }
            }
        } catch {
            compilationError = error.localizedDescription
            debugHistory += "X:\(error) "
        }
    }

    // MARK: - LaTeX Compilation

    private func compileLaTeX() async {
        // LaTeX requires a file URL — the document must be saved to disk first.
        // For unsaved documents, write to a temp directory.
        let sourceText = document.source
        debugStatus = "2:latex,src=\(sourceText.count)ch"
        debugHistory += "2:\(sourceText.count) "

        // Resolve the engine
        let engineRaw = latexDefaultEngine
        let engine = LaTeXEngine(rawValue: engineRaw) ?? .pdflatex

        // Get or create a temp file URL for compilation
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imprint-latex-\(document.id.uuidString)")
        let sourceURL = tempDir.appendingPathComponent("main.tex")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try sourceText.data(using: .utf8)?.write(to: sourceURL)
        } catch {
            compilationError = "Failed to write temp file: \(error.localizedDescription)"
            debugHistory += "X:write "
            return
        }

        debugStatus = "3:engine=\(engine.rawValue)"
        debugHistory += "3:\(engine.rawValue) "

        let options = LaTeXCompileOptions(
            engine: engine,
            shellEscape: latexShellEscape
        )

        do {
            let result = try await LaTeXCompilationService.shared.compile(
                sourceURL: sourceURL,
                engine: engine,
                options: options
            )

            latexCompilationTimeMs = result.compilationTimeMs
            latexDiagnostics = result.errors + result.warnings
            DocumentRegistry.shared.cachedDiagnostics[document.id] = latexDiagnostics

            if result.isSuccess, let data = result.pdfData {
                pdfData = data
                sourceMapEntries = []
                DocumentRegistry.shared.cachePDF(data, for: document.id)

                // Cancel previous post-compile tasks before starting new ones
                postCompileTask?.cancel()
                let capturedSynctexURL = result.synctexURL
                let capturedSourceURL = sourceURL
                postCompileTask = Task {
                    // Load SyncTeX data for bidirectional sync
                    if let synctexURL = capturedSynctexURL {
                        do {
                            try await SyncTeXService.shared.load(from: synctexURL)
                        } catch {
                            log("SyncTeX load failed: \(error)")
                        }
                    }

                    guard !Task.isCancelled else { return }

                    // Scan project dependencies for sidebar
                    await LaTeXProjectService.shared.scanDependencies(from: capturedSourceURL)
                    let files = await LaTeXProjectService.shared.allProjectFiles
                    let mainFile = await LaTeXProjectService.shared.mainFile
                    await MainActor.run {
                        latexProjectFiles = files
                        latexMainFileURL = mainFile
                    }
                }
                debugStatus = "5:ok,\(data.count)b,\(result.compilationTimeMs)ms"
                debugHistory += "5:ok "
            } else {
                compilationError = result.errors.map(\.message).joined(separator: "\n")
                if compilationError?.isEmpty ?? true {
                    compilationError = "Compilation failed (exit code \(result.exitCode))"
                }
                // Log first 500 chars of compilation output for debugging
                let logSnippet = String(result.logOutput.prefix(500))
                Logger.compilation.errorCapture("LaTeX failed (exit \(result.exitCode)): errors=\(result.errors.map(\.message)), log=\(logSnippet)", category: "latex")
                debugHistory += "E "
            }

            // Surface warnings (filter box warnings if disabled)
            let showBoxWarnings = latexShowBoxWarnings
            compilationWarnings = result.warnings
                .filter { diag in
                    if !showBoxWarnings && (diag.message.hasPrefix("Overfull") || diag.message.hasPrefix("Underfull")) {
                        return false
                    }
                    return true
                }
                .map { "\($0.file):\($0.line): \($0.message)" }

        } catch {
            compilationError = error.localizedDescription
            Logger.compilation.errorCapture("LaTeX compile threw: \(error)", category: "latex")
            debugHistory += "X:\(error) "
        }
    }
}

// MARK: - Edit Mode Segmented Control

/// Custom segmented control for edit modes with proper accessibility identifiers
struct EditModeSegmentedControl: View {
    @Binding var selection: EditMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EditMode.allCases, id: \.self) { mode in
                EditModeSegmentButton(
                    mode: mode,
                    isSelected: selection == mode,
                    action: { selection = mode }
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

/// Individual segment button with proper accessibility
struct EditModeSegmentButton: View {
    let mode: EditMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: mode.iconName)
                .frame(width: 28, height: 20)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(background)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help(mode.helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode.helpText)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(mode.accessibilityIdentifier)
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            Color(nsColor: .controlAccentColor).opacity(0.2)
        } else {
            Color.clear
        }
    }
}


// MARK: - Notification Handlers

/// ViewModifier to handle menu/notification-driven actions, extracted to reduce type-check complexity.
private struct NotificationHandlersModifier: ViewModifier {
    let appState: AppState
    let onCompile: () -> Void
    let onExportPDF: () -> Void
    let onPrintPDF: () -> Void
    let onShowSymbolPalette: () -> Void

    func body(content: Content) -> some View {
        content
            .onNotifications([
                (.insertCitation, { _ in appState.showingCitationPicker = true }),
                (.compileDocument, { _ in onCompile() }),
                (.showVersionHistory, { _ in appState.showingVersionHistory = true }),
                (.toggleFocusMode, { _ in appState.isFocusMode.toggle() }),
                (.toggleAIAssistant, { _ in withAnimation { appState.showingAIAssistant.toggle() } }),
                (.toggleCommentsSidebar, { _ in withAnimation { appState.showingComments.toggle() } }),
                (.exportPDF, { _ in onExportPDF() }),
                (.printPDF, { _ in onPrintPDF() }),
                (.showSymbolPalette, { _ in onShowSymbolPalette() }),
            ])
    }
}

// MARK: - Automation Handlers

/// ViewModifier to process pending automation operations from the HTTP API.
/// Uses the shared OperationQueueModifier from ImpressOperationQueue.
private struct AutomationHandlersModifier: ViewModifier {
    @Binding var document: ImprintDocument

    func body(content: Content) -> some View {
        content
            .operationQueueHandler(
                registry: DocumentRegistry.shared,
                entityId: document.id
            ) { operation in
                processOperation(operation)
            }
    }

    private func processOperation(_ operation: DocumentOperation) {
        // Build updated document BEFORE mutating binding
        var updatedDoc = document

        switch operation {
        case .updateContent(_, let source, let title):
            if let source = source {
                updatedDoc.source = source
                document.source = source
            }
            if let title = title {
                updatedDoc.title = title
                document.title = title
            }
            updatedDoc.modifiedAt = Date()

        case .insertText(_, let position, let text):
            updatedDoc.insertText(text, at: position)
            document.insertText(text, at: position)

        case .deleteText(_, let start, let end):
            updatedDoc.deleteText(in: start..<end)
            document.deleteText(in: start..<end)

        case .replaceRange(_, let start, let end, let text):
            // Atomic range replace — safer than delete+insert because it
            // keeps the binding in one consistent state for SwiftUI.
            let clampedEnd = min(max(start, end), updatedDoc.source.count)
            let clampedStart = min(max(0, start), clampedEnd)
            if clampedStart < clampedEnd {
                updatedDoc.deleteText(in: clampedStart..<clampedEnd)
                document.deleteText(in: clampedStart..<clampedEnd)
            }
            updatedDoc.insertText(text, at: clampedStart)
            document.insertText(text, at: clampedStart)
            updatedDoc.modifiedAt = Date()
            document.modifiedAt = Date()

        case .replace(_, let search, let replacement, let all):
            if all {
                updatedDoc.source = updatedDoc.source.replacingOccurrences(of: search, with: replacement)
                document.source = document.source.replacingOccurrences(of: search, with: replacement)
            } else if let range = updatedDoc.source.range(of: search) {
                updatedDoc.source.replaceSubrange(range, with: replacement)
                if let bindingRange = document.source.range(of: search) {
                    document.source.replaceSubrange(bindingRange, with: replacement)
                }
            }
            updatedDoc.modifiedAt = Date()
            document.modifiedAt = Date()

        case .addCitation(_, let citeKey, let bibtex):
            updatedDoc.bibliography[citeKey] = bibtex
            updatedDoc.modifiedAt = Date()
            document.addCitation(key: citeKey, bibtex: bibtex)

        case .removeCitation(_, let citeKey):
            updatedDoc.bibliography.removeValue(forKey: citeKey)
            updatedDoc.modifiedAt = Date()
            document.bibliography.removeValue(forKey: citeKey)
            document.modifiedAt = Date()

        case .updateMetadata(_, let title, let authors):
            if let title = title {
                updatedDoc.title = title
                document.title = title
            }
            if let authors = authors {
                updatedDoc.authors = authors
                document.authors = authors
            }
            updatedDoc.modifiedAt = Date()
            document.modifiedAt = Date()
        }

        // Update registry so HTTP API sees the change
        DocumentRegistry.shared.register(updatedDoc, fileURL: nil)

        // Mark the operation as complete so pollers on /api/operations/{id}
        // see the real status instead of "pending".
        OperationTracker.shared.markCompleted(id: operation.id)

        NSLog("[Automation] Processed operation for document %@: %@", document.id.uuidString, operation.operationDescription)
    }
}

// MARK: - Preview

#Preview {
    ContentView(document: .constant(ImprintDocument()))
        .environment(AppState())
}
#endif // os(macOS)
