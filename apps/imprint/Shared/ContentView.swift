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
    @Environment(\.openWindow) private var openWindow

    @State private var cursorPosition: Int = 0

    /// Cursor for the second split-editor view (independent of the primary)
    @State private var secondaryCursorPosition: Int = 0

    /// Owns the compile/preview output state + compile orchestration. The view
    /// reads `vm.pdfData` / `vm.isCompiling` / … declaratively and drives it via
    /// `vm.compile(makeCompileInputs())`.
    @State private var vm = ImprintDocumentViewModel()

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
    @State private var syncTeXHighlight: SyncTeXPosition?
    @State private var showingSymbolPalette = false

    // AI Context Menu state
    @State private var showingAIContextMenu = false
    @State private var currentSuggestion: RewriteSuggestion?
    @State private var aiErrorMessage: String?
    /// Running inline AI author-task (streaming into `currentSuggestion`).
    @State private var inlineAITask: Task<Void, Never>?
    /// Ranked citation suggestions panel state (nil = hidden).
    @State private var citationSuggestions: [CitationSuggestionService.ClaimSuggestion]?
    @State private var citationSuggestLoading = false
    @State private var citationSuggestRange: NSRange?
    @State private var citationSuggestTask: Task<Void, Never>?

    #if os(macOS)
    /// Comment service for this document (macOS only)
    @State private var commentService = CommentService()

    /// Veusz plot picker sheet visibility (Cmd+Shift+I / "Insert Veusz Plot…")
    @State private var showingVeuszPlotPicker = false
    #endif

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
        // Single HSplitView — no nesting at top level.
        //
        // Layout note: HSplitView at the top level of a DocumentGroup
        // does NOT auto-fill the window the way NavigationSplitView did.
        // Without the `.frame(maxWidth/maxHeight: .infinity)` below, the
        // split view collapses to children's intrinsic size and gets
        // centered in the window — a regression introduced in b826461
        // when the layout was rewritten away from NavigationSplitView.
        HSplitView {
            if appState.showingOutline {
                outlineSidebar
            }

            centerPane

            paperPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(LayoutSystemModifier(
            appState: appState,
            documentID: document.id,
            documentTitle: document.title,
            pdfData: vm.pdfData,
            isCompiling: vm.isCompiling
        ))
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
                    Task { await vm.compile(makeCompileInputs()) }
                } label: {
                    if vm.isCompiling {
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

                // Pane toggles — every surface is one visible click, and the
                // filled/unfilled icon shows its state at a glance. These
                // mirror the View menu items.
                Button {
                    withAnimation { appState.showingOutline.toggle() }
                } label: {
                    Image(systemName: "sidebar.leading")
                        .symbolVariant(appState.showingOutline ? .fill : .none)
                }
                .help(appState.showingOutline ? "Hide Outline" : "Show Outline")
                .accessibilityIdentifier("toolbar.outlineButton")

                Button {
                    withAnimation { appState.isEditorSplit.toggle() }
                } label: {
                    Image(systemName: appState.isEditorSplit ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                }
                .help(appState.isEditorSplit ? "Close Split Editor" : "Split Editor")
                .accessibilityIdentifier("toolbar.splitEditorButton")

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

                #if os(macOS)
                // Veusz plots inspector
                Button {
                    withAnimation { appState.showingVeuszPlots.toggle() }
                } label: {
                    Image(systemName: "chart.xyaxis.line")
                        .symbolVariant(appState.showingVeuszPlots ? .fill : .none)
                }
                .help(appState.showingVeuszPlots ? "Hide Plots Panel" : "Show Plots Panel")
                .accessibilityIdentifier("toolbar.plotsButton")

                // Detached PDF window (second display / separate window)
                Button {
                    NotificationCenter.default.post(name: .openDetachedPDF, object: nil)
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                }
                .help("Open PDF in Separate Window")
                .accessibilityIdentifier("toolbar.detachedPDFButton")
                #endif

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

                // Compile status — one glanceable badge instead of the old
                // debug text dump. Errors click through to the inline
                // CompilationErrorView panel; details live in the tooltip.
                if let err = vm.compilationError, !err.isEmpty {
                    Button {
                        // The error panel renders under the editor in split
                        // view — make sure it's on screen.
                        if appState.editMode == .textOnly {
                            withAnimation { appState.editMode = .splitView }
                        }
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    .help("Compilation failed — click to show errors.\n\(err.prefix(300))")
                    .accessibilityIdentifier("toolbar.compileStatus")
                    .accessibilityValue("pdf=\(vm.pdfData?.count ?? 0)b")
                } else if let pdf = vm.pdfData {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                        .help("Compiled OK — PDF \(ByteCountFormatter.string(fromByteCount: Int64(pdf.count), countStyle: .file))\(debugCompileDetail)")
                        .accessibilityIdentifier("toolbar.compileStatus")
                        .accessibilityValue("pdf=\(pdf.count)b")
                }
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
            onCompile: { Task { await vm.compile(makeCompileInputs()) } },
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
            await vm.compile(makeCompileInputs())
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
            let fileName = vm.latexMainFileURL?.lastPathComponent ?? document.title + ".tex"
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
        .modifier(VeuszWiringModifier(
            document: $document,
            cursorPosition: cursorPosition,
            showingVeuszPlotPicker: $showingVeuszPlotPicker
        ))
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
        // Non-modal, flow-preserving AI result preview (replaces the old modal
        // sheet). Driven from the cell brackets / selection AI menu and from the
        // Cmd+Shift+A picker; streams the result and applies it undo-friendly.
        .onReceive(NotificationCenter.default.publisher(for: .runInlineAITask)) { note in
            guard let actionId = note.userInfo?["actionId"] as? String,
                  let range = (note.userInfo?["range"] as? NSValue)?.rangeValue else { return }
            startInlineAITask(actionId: actionId, range: range)
        }
        .overlay(alignment: .topTrailing) { inlineAITaskOverlay }
        .overlay(alignment: .top) { citationSuggestionOverlay }
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
        .overlay(alignment: .top) { aiErrorBanner }
        #endif
    }

    /// Declarative layout system + detached-PDF plumbing, extracted from the
    /// `mainContent` modifier chain (ContentView.body is at the type-checker's
    /// "reasonable time" limit — keep new modifiers out of the main chain).
    private struct LayoutSystemModifier: ViewModifier {
        let appState: AppState
        let documentID: UUID
        let documentTitle: String
        let pdfData: Data?
        let isCompiling: Bool
        @Environment(\.openWindow) private var openWindow

        func body(content: Content) -> some View {
            content
                .task {
                    // Restore the last pane arrangement (named-layout system).
                    // AppState is app-global, so re-applying per window is
                    // idempotent.
                    LayoutStore.shared.lastState().apply(to: appState)
                }
                .onChange(of: PaneLayoutState.capture(from: appState)) { _, _ in
                    // Remember the live arrangement so new windows and the
                    // next launch start from it (tiny JSON in UserDefaults).
                    LayoutStore.shared.rememberCurrent(appState)
                }
                // Publish compiled output so the detached PDF window (second
                // display) observes it without coupling to this view model.
                .onChange(of: pdfData) { _, data in
                    CompiledPDFStore.shared.publish(
                        documentID: documentID, title: documentTitle,
                        pdfData: data, isCompiling: isCompiling
                    )
                }
                .onChange(of: isCompiling) { _, compiling in
                    CompiledPDFStore.shared.publish(
                        documentID: documentID, title: documentTitle,
                        pdfData: pdfData, isCompiling: compiling
                    )
                }
                .onReceive(NotificationCenter.default.publisher(for: .openDetachedPDF)) { _ in
                    openWindow(id: "pdf-preview", value: documentID)
                }
        }
    }

    /// Non-modal, auto-dismissing banner for AI errors (preserves flow — no alert).
    @ViewBuilder
    private var aiErrorBanner: some View {
        if let message = aiErrorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.callout).lineLimit(3)
                Button {
                    aiErrorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
            .shadow(radius: 8, y: 3)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: message) {
                try? await Task.sleep(for: .seconds(6))
                if aiErrorMessage == message { aiErrorMessage = nil }
            }
        }
    }

    /// Center pane: the mode content flanked by the optional Comments (left)
    /// and AI Chat (right) sidebars. This is the render path for the
    /// `showingComments` / `showingAIAssistant` toggles — panes are described
    /// by AppState (the declarative layout state), never hard-wired.
    @ViewBuilder
    private var centerPane: some View {
        HStack(spacing: 0) {
            #if os(macOS)
            if appState.showingComments {
                CommentsSidebarView(
                    commentService: commentService,
                    onNavigateToRange: { range in
                        cursorPosition = range.start
                    }
                )
                .transition(.move(edge: .leading))

                Divider()
            }
            #endif

            modeContent
                .frame(maxWidth: .infinity)

            #if os(macOS)
            if appState.showingThroughline {
                Divider()

                ThroughlinePaneView(
                    document: $document,
                    onNavigateToSection: { sectionKey in
                        navigateToSection(slugKey: sectionKey)
                    }
                )
                .transition(.move(edge: .trailing))
            }

            if appState.showingAIAssistant {
                Divider()

                AIChatSidebar(
                    selectedText: Binding(
                        get: { appState.selectedText },
                        set: { appState.selectedText = $0 }
                    ),
                    documentSource: $document.source,
                    onInsertText: { text in
                        insertTextAtCursor(text)
                    }
                )
                .transition(.move(edge: .trailing))
            }
            #endif
        }
        .animation(.easeInOut(duration: 0.15), value: appState.showingComments)
        .animation(.easeInOut(duration: 0.15), value: appState.showingAIAssistant)
        .animation(.easeInOut(duration: 0.15), value: appState.showingThroughline)
    }

    /// Move the cursor to the heading whose slug key matches (throughline
    /// anchor click-through). Slug keys are derived from heading titles by
    /// `ThroughlineText.sectionKey(forHeading:)`.
    private func navigateToSection(slugKey: String) {
        #if os(macOS)
        for section in ThroughlineCoordinator.extractSections(of: document)
        where section.key == slugKey {
            if let range = document.source.range(of: "= \(section.title)")
                ?? document.source.range(of: section.title) {
                cursorPosition = document.source.distance(
                    from: document.source.startIndex, to: range.lowerBound)
            }
            return
        }
        #endif
    }

    /// The source editor area: one editor, or two views into the same document
    /// (split stacked or side by side). Both bind the same `$document.source`;
    /// each has its own cursor, so one part can be read/edited while another
    /// part stays in view.
    @ViewBuilder
    private var editorArea: some View {
        if appState.isEditorSplit {
            if appState.editorSplitSideBySide {
                HSplitView {
                    primaryEditor
                        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                    secondaryEditor
                        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VSplitView {
                    primaryEditor
                        .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
                    secondaryEditor
                        .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
                }
            }
        } else {
            primaryEditor
        }
    }

    private var primaryEditor: some View {
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

    /// Second view into the same buffer. Own cursor; selection changes still
    /// feed AppState so AI tasks work from whichever editor was touched last.
    private var secondaryEditor: some View {
        SourceEditorView(
            source: $document.source,
            cursorPosition: $secondaryCursorPosition,
            syntaxMode: appState.documentFormat,
            onSelectionChange: { selectedText, selectedRange in
                appState.selectedText = selectedText
                appState.selectedRange = selectedRange
            }
        )
    }

    /// The mode-specific main pane (text-only / split-view / direct-pdf).
    /// Extracted to keep `mainContent` simple enough for the type-checker.
    @ViewBuilder
    private var modeContent: some View {
        @Bindable var appState = appState
        switch appState.editMode {
        case .textOnly:
            editorArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .splitView:
            splitViewMode
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .directPdf:
            DirectPDFView(
                document: $document,
                pdfData: vm.pdfData,
                sourceMapEntries: vm.sourceMapEntries,
                cursorPosition: $cursorPosition
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Extra compile detail appended to the status-badge tooltip in debug
    /// builds (the old toolbar debug string, now out of the visible chrome).
    private var debugCompileDetail: String {
        #if DEBUG
        return vm.debugHistory.isEmpty ? "" : "\n\(vm.debugHistory)"
        #else
        return ""
        #endif
    }

    /// Editor + PDF preview side by side (the .splitView edit mode).
    /// Inner HSplitView gives native macOS drag-to-resize.
    @ViewBuilder
    private var splitViewMode: some View {
        @Bindable var appState = appState
        HSplitView {
            VStack(spacing: 0) {
                editorArea
                    .frame(maxHeight: .infinity)

                CompilationErrorView(
                    diagnostics: vm.latexDiagnostics,
                    errors: vm.compilationError,
                    warnings: vm.compilationWarnings,
                    onNavigateToLine: { line in navigateToLine(line) }
                )
            }
            .frame(minWidth: 250, idealWidth: 500, maxHeight: .infinity)

            PDFPreviewView(
                pdfData: vm.pdfData,
                isCompiling: vm.isCompiling,
                sourceMapEntries: vm.sourceMapEntries,
                cursorPosition: cursorPosition,
                onInverseSync: appState.documentFormat == .latex ? { _, line, _ in
                    navigateToLine(line)
                } : nil,
                syncTeXHighlight: syncTeXHighlight
            )
            .frame(minWidth: 250, idealWidth: 500, maxHeight: .infinity)
        }
    }

    /// Optional right-side paper detail panel (Track E). Opens via cite-key
    /// action, floats over the detail area with a fixed width.
    @ViewBuilder
    private var paperPanel: some View {
        if let pubID = openPaperPublicationID {
            PaperDetailPanel(
                publicationID: pubID,
                dataSource: ImprintPublicationService.shared,
                onClose: { openPaperPublicationID = nil }
            )
            .frame(width: 420)
            .frame(maxHeight: .infinity)
            .background(.regularMaterial)
        }
    }

    /// Sidebar with outline, project files, and cited papers.
    private var outlineSidebar: some View {
        List {
            DocumentOutlineView(
                source: document.source,
                format: appState.documentFormat,
                documentID: document.id,
                onNavigateToLine: { line in navigateToLine(line) },
                cursorLine: currentCursorLine
            )
            .accessibilityIdentifier("sidebar.outline")

            if appState.documentFormat == .latex && !vm.latexProjectFiles.isEmpty {
                LaTeXProjectSidebarView(
                    projectFiles: vm.latexProjectFiles,
                    mainFileURL: vm.latexMainFileURL,
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
        guard let range = appState.selectedRange else {
            insertTextAtCursor(text)
            return
        }
        applyAIResult(text, range: range)
    }

    /// Apply AI-produced `text` over an explicit source `range` (from a cell
    /// bracket, a selection, or the picker). Mutates the document's source of
    /// truth; the editor re-syncs and re-highlights.
    private func applyAIResult(_ text: String, range: NSRange) {
        Logger.ai.infoCapture("applyAIResult: range=\(range.location),\(range.length) newLen=\(text.count) srcLen=\(document.source.count)", category: "ai")
        // Read-modify-assign through a local so the @Binding setter definitely
        // fires (nested mutation of a computed property can hit a temporary).
        var newSource = document.source
        guard let swiftRange = Range(range, in: newSource) else {
            Logger.ai.errorCapture("applyAIResult: Range() nil for \(range.location),\(range.length) — inserting at cursor", category: "ai")
            insertTextAtCursor(text)
            return
        }
        newSource.replaceSubrange(swiftRange, with: text)
        document.source = newSource
        cursorPosition = range.location + text.count
        appState.selectedText = ""
        appState.selectedRange = NSRange(location: cursorPosition, length: 0)
        Logger.ai.infoCapture("applyAIResult: applied; srcLen now \(document.source.count)", category: "ai")
    }

    // MARK: - Inline AI Author-Tasks

    /// Non-modal ranked-citation confirm panel.
    @ViewBuilder
    private var citationSuggestionOverlay: some View {
        if citationSuggestLoading || citationSuggestions != nil {
            CitationSuggestionPanel(
                suggestions: citationSuggestions ?? [],
                isLoading: citationSuggestLoading,
                onInsert: { applyCitations($0) },
                onDismiss: { dismissCitationSuggestions() }
            )
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Non-modal preview card for the running/finished inline AI task.
    @ViewBuilder
    private var inlineAITaskOverlay: some View {
        if let suggestion = currentSuggestion {
            InlineAITaskCard(
                suggestion: suggestion,
                isAdvisory: !suggestion.action.outputMode.appliesToBuffer,
                onAccept: { text in
                    applyAIResult(text, range: suggestion.range)
                    dismissInlineAITask()
                },
                onDiscard: { dismissInlineAITask() },
                onRetry: { startInlineAITask(actionId: suggestion.action.id, range: suggestion.range) }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Start an AI author-task on a source range: seed the non-modal preview
    /// card and stream the model output into it. On-device by default (no key).
    private func startInlineAITask(actionId: String, range: NSRange) {
        Logger.ai.infoCapture("startInlineAITask: \(actionId) range=\(range.location),\(range.length) sourceLen=\(document.source.count)", category: "ai")
        guard let action = AIContextMenuService.shared.actions.first(where: { $0.id == actionId }) else {
            Logger.ai.errorCapture("startInlineAITask: unknown action \(actionId)", category: "ai")
            return
        }
        let source = document.source as NSString
        guard range.location >= 0, NSMaxRange(range) <= source.length else {
            Logger.ai.errorCapture("startInlineAITask: range out of bounds \(range.location),\(range.length) vs \(source.length)", category: "ai")
            return
        }
        let selectedText = source.substring(with: range)
        let context = inlineTaskContext(for: range)

        inlineAITask?.cancel()

        switch action.outputMode {
        case .proposeCitations:
            // Extract claims → search imbib → show a ranked confirm panel.
            currentSuggestion = nil
            startCitationSuggestions(range: range, text: selectedText)

        case .annotateAsComment:
            startReviewAnnotations(action: action, range: range, passage: selectedText, context: context)

        default:
            // replace / advisory / sideBySideDiff / insertAfter → streaming card
            currentSuggestion = RewriteSuggestion(
                originalText: selectedText,
                suggestedText: "",
                action: action,
                range: range,
                isStreaming: true
            )
            inlineAITask = Task {
                do {
                    for try await partial in AIContextMenuService.shared.executeActionStreaming(
                        action, selectedText: selectedText, range: range, context: context
                    ) {
                        currentSuggestion = partial
                    }
                } catch is CancellationError {
                    // dismissed by the user
                } catch {
                    currentSuggestion = nil
                    aiErrorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: Review → inline comments

    /// Review output mode: ask the model for structured findings, then anchor
    /// each as a comment on its quoted span (never mutates the buffer). A
    /// lightweight streaming card shows progress while the model works.
    private func startReviewAnnotations(action: AIAction, range: NSRange, passage: String, context: DocumentContext) {
        currentSuggestion = RewriteSuggestion(
            originalText: passage, suggestedText: "", action: action, range: range, isStreaming: true
        )
        let heading = context.sectionHeading
        inlineAITask = Task {
            do {
                let system = Self.reviewFindingsPrompt(sectionHeading: heading)
                var full = ""
                for try await chunk in AIAssistantService.shared.streamMessage(systemPrompt: system, userMessage: passage) {
                    try Task.checkCancellation()
                    full += chunk
                }
                let findings = Self.parseReviewFindings(full)
                let ns = document.source as NSString
                var added = 0
                for finding in findings {
                    let target = Self.locate(quote: finding.quote, within: range, in: ns) ?? range
                    _ = commentService.addComment(
                        content: finding.commentBody,
                        at: TextRange(nsRange: target),
                        authorAgentId: "imprint-ai",
                        authorName: "AI Review"
                    )
                    added += 1
                }
                if added > 0 {
                    appState.showingComments = true
                    // Replace the progress spinner with a clear confirmation so the
                    // card doesn't just vanish (the findings are anchored comments,
                    // not inline text — see the Comments panel).
                    currentSuggestion = RewriteSuggestion(
                        originalText: passage,
                        suggestedText: "Added \(added) review comment\(added == 1 ? "" : "s"). Open the Comments panel to see them.",
                        action: action,
                        range: range,
                        isStreaming: false
                    )
                    Logger.ai.infoCapture("Review: added \(added) comments (\(action.id))", category: "ai")
                } else {
                    currentSuggestion = nil
                    aiErrorMessage = "AI review found nothing specific to flag in this passage."
                }
            } catch is CancellationError {
                currentSuggestion = nil
            } catch {
                currentSuggestion = nil
                aiErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Suggest citations

    /// Extract citation-worthy claims from the passage, search imbib for each,
    /// and show a non-modal confirm panel. Nothing is inserted automatically.
    private func startCitationSuggestions(range: NSRange, text: String) {
        citationSuggestTask?.cancel()
        citationSuggestRange = range
        citationSuggestions = nil
        citationSuggestLoading = true
        citationSuggestTask = Task {
            let result = await CitationSuggestionService.shared.suggest(text: text)
            if Task.isCancelled { return }
            citationSuggestLoading = false
            citationSuggestions = result
            if result.allSatisfy({ $0.candidates.isEmpty }) && !result.isEmpty {
                Logger.ai.infoCapture("Citation suggest: claims found but no library matches", category: "ai")
            }
        }
    }

    private func dismissCitationSuggestions() {
        citationSuggestTask?.cancel()
        citationSuggestTask = nil
        citationSuggestions = nil
        citationSuggestLoading = false
        citationSuggestRange = nil
    }

    /// Insert the chosen citations at the end of the target range (grouped),
    /// and register each in the document's bibliography.
    private func applyCitations(_ selected: [CitationResult]) {
        guard !selected.isEmpty, let range = citationSuggestRange else { dismissCitationSuggestions(); return }
        // Register bib entries so the .bib projection + compile pick them up.
        for c in selected where !c.bibtex.isEmpty {
            document.addCitation(key: c.citeKey, bibtex: c.bibtex)
        }
        let keys = selected.map(\.citeKey)
        let isLatex = appState.documentFormat == .latex
        let citeText = isLatex ? "\\cite{\(keys.joined(separator: ","))}" : keys.map { "@\($0)" }.joined(separator: " ")
        // Insert at the end of the range (author can reposition).
        let insertAt = min(NSMaxRange(range), (document.source as NSString).length)
        applyAIResult(citeText, range: NSRange(location: insertAt, length: 0))
        Logger.ai.infoCapture("Inserted \(keys.count) citation(s): \(keys.joined(separator: ","))", category: "ai")
        dismissCitationSuggestions()
    }

    private struct ReviewFinding { let quote: String; let commentBody: String }

    private static func reviewFindingsPrompt(sectionHeading: String?) -> String {
        let whereClause = sectionHeading.map { " from the section \"\($0)\"" } ?? ""
        return """
        You are a critical peer reviewer of a scientific manuscript. Review the passage\(whereClause) and identify up to 5 specific issues: unsupported claims, weak or circular arguments, logical gaps, vague quantities, or missing evidence or citations.
        For EACH issue output exactly one line, with no blank lines, in this pipe-delimited format:
        QUOTE ||| ISSUE ||| SUGGESTION
        - QUOTE: 4 to 12 words copied VERBATIM from the passage that the issue is about (it must appear exactly in the text).
        - ISSUE: the problem, one sentence.
        - SUGGESTION: a concrete fix, one sentence.
        Output only these lines. If the passage has no substantive issues, output exactly: NONE
        """
    }

    private static func parseReviewFindings(_ raw: String) -> [ReviewFinding] {
        var out: [ReviewFinding] = []
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let parts = rawLine.components(separatedBy: "|||").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            let quote = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\"'`- "))
            if quote.isEmpty || quote.uppercased() == "NONE" { continue }
            let issue = parts[1]
            let suggestion = parts.count >= 3 ? parts[2] : ""
            let body = suggestion.isEmpty ? issue : "\(issue)\n\nSuggested fix: \(suggestion)"
            out.append(ReviewFinding(quote: quote, commentBody: body))
        }
        return out
    }

    private static func locate(quote: String, within range: NSRange, in ns: NSString) -> NSRange? {
        guard !quote.isEmpty, NSMaxRange(range) <= ns.length else { return nil }
        let found = ns.range(of: quote, options: [], range: range)
        return found.location != NSNotFound ? found : nil
    }

    private func dismissInlineAITask() {
        inlineAITask?.cancel()
        inlineAITask = nil
        AIContextMenuService.shared.cancelCurrentAction()
        currentSuggestion = nil
    }

    /// Rich prompt context for a range (section body/heading, outline,
    /// surrounding sections, cited papers) via the shared PromptContextBuilder.
    private func inlineTaskContext(for range: NSRange) -> DocumentContext {
        let format: SectionFormat = appState.documentFormat == .latex ? .latex : .typst
        return PromptContextBuilder.build(
            range: range,
            source: document.source,
            documentTitle: document.title,
            documentID: document.id,
            format: format
        )
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
            await vm.compile(makeCompileInputs())
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

    /// The caret's current 0-based line number, derived from `cursorPosition`.
    /// Read in `body` so the outline highlight tracks the caret reactively.
    private var currentCursorLine: Int {
        let end = min(max(0, cursorPosition), document.source.count)
        return document.source.prefix(end).reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
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
        guard let data = vm.pdfData, !data.isEmpty else {
            // No PDF yet — compile first, then print.
            // Capture pdfData after compile returns (still on MainActor).
            Task { @MainActor in
                await vm.compile(makeCompileInputs())
                // Re-read @State after compile has set it
                guard let data = vm.pdfData, !data.isEmpty else { return }
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
        guard let data = vm.pdfData, !data.isEmpty else {
            // No PDF yet — compile first, then export.
            Task { @MainActor in
                await vm.compile(makeCompileInputs())
                guard let data = vm.pdfData, !data.isEmpty else { return }
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

    /// Snapshot the inputs a compile needs from the view's live state, so the
    /// view model compiles from a pure value type (no live @State reads).
    private func makeCompileInputs() -> CompileInputs {
        CompileInputs(
            source: document.source,
            format: appState.documentFormat,
            previewFormat: previewFormat,
            documentID: document.id,
            documentTitle: document.title,
            latexEngine: latexDefaultEngine,
            latexShellEscape: latexShellEscape,
            latexShowBoxWarnings: latexShowBoxWarnings
        )
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
                (.toggleThroughlinePane, { _ in withAnimation { appState.showingThroughline.toggle() } }),
                (.toggleVeuszPlotsPanel, { _ in withAnimation { appState.showingVeuszPlots.toggle() } }),
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
