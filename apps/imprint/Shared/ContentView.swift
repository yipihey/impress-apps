#if os(macOS)
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import ImprintCore
import ImpressKeyboard
import ImpressOperationQueue

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

    // Auto-compile
    @AppStorage("imprint.autoCompile") private var autoCompileEnabled = true
    @AppStorage("imprint.compileDebounceMs") private var compileDebounceMs = 300
    @AppStorage("imprint.previewFormat") private var previewFormat = "pdf"
    @State private var autoCompileTask: Task<Void, Never>?

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

    var body: some View {
        @Bindable var appState = appState

        ZStack {
            mainContent

            // Focus Mode overlay
            if appState.isFocusMode {
                FocusModeView(
                    source: $document.source,
                    cursorPosition: $cursorPosition,
                    isActive: $appState.isFocusMode
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.isFocusMode)
    }

    @ViewBuilder
    private var mainContent: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            // Sidebar: Document outline and cited papers
            List {
                // Document outline section
                DocumentOutlineView(source: document.source)
                    .accessibilityIdentifier("sidebar.outline")

                // Cited papers section (from imbib, hidden when not available)
                #if os(macOS)
                CitedPapersSection(source: document.source)
                #endif
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress { press in
                handleVimNavigation(press)
            }
        } detail: {
            // Main editor area
            editorView
                .accessibilityIdentifier("content.editorArea")
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Edit mode picker - custom segmented control for accessibility
                EditModeSegmentedControl(selection: $appState.editMode)
                    .accessibilityIdentifier("toolbar.editModePicker")

                Spacer()

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
                .help("Refresh Preview (⌘B)")
                .keyboardShortcut("B", modifiers: [.command])
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
            onPrintPDF: { printPDF() }
        ))
        .task {
            await compile()
        }
        .onChange(of: document.source) { _, _ in
            scheduleAutoCompile()
        }
        // HTTP API automation handlers (applied before platform-specific handlers)
        .modifier(AutomationHandlersModifier(document: $document))
        #if os(macOS)
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
            HSplitView {
                SourceEditorView(
                    source: $document.source,
                    cursorPosition: $cursorPosition,
                    onSelectionChange: { selectedText, selectedRange in
                        appState.selectedText = selectedText
                        appState.selectedRange = selectedRange
                    }
                )
                .frame(minWidth: 300, maxHeight: .infinity)

                VStack(spacing: 0) {
                    if previewFormat == "svg" && !svgPages.isEmpty {
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
                            cursorPosition: cursorPosition
                        )
                        .frame(maxHeight: .infinity)
                    }

                    CompilationErrorView(
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
        // Don't intercept when editing text
        guard !TextFieldFocusDetection.isTextFieldFocused() else { return .ignored }

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
    private func scheduleAutoCompile() {
        guard autoCompileEnabled else { return }
        autoCompileTask?.cancel()
        let delayMs = compileDebounceMs
        autoCompileTask = Task {
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
            await compile()
        }
    }

    // MARK: - Navigation

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
        // Use NSLog to ensure it appears in Console.app and system logs
        NSLog("[ContentView] %@", message)
    }

    private func compile() async {
        log("compile() started")
        debugHistory = ""
        debugStatus = "1:started"
        debugHistory += "1 "
        isCompiling = true
        compilationError = nil
        compilationWarnings = []

        // Capture @State/AppStorage before any async work
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
                // SVG rendering — per-page SVG strings for split view
                debugStatus = "4:rendering(svg)"
                debugHistory += "4svg "
                log("Calling renderer.renderSVG()")
                let output = try await renderer.renderSVG(sourceText, options: options)
                debugStatus = "5:done,ok=\(output.isSuccess),pages=\(output.svgPages.count)"
                debugHistory += "5:\(output.svgPages.count)p "
                log("renderer.renderSVG() completed, success: \(output.isSuccess), pages: \(output.svgPages.count)")

                if output.isSuccess {
                    svgPages = output.svgPages
                    sourceMapEntries = output.sourceMapEntries
                    compilationWarnings = output.warnings

                    // Also render PDF for Direct PDF mode, export, and print.
                    // This is fast because the persistent engine already compiled the document.
                    let pdfOutput = try await renderer.render(sourceText, options: options)
                    if pdfOutput.isSuccess {
                        pdfData = pdfOutput.pdfData
                        DocumentRegistry.shared.cachePDF(pdfOutput.pdfData, for: document.id)
                    }

                    debugStatus = "6:set,\(output.svgPages.count)p,map=\(output.sourceMapEntries.count)"
                    debugHistory += "6:ok "
                    log("SVG pages set: \(output.svgPages.count), source map entries: \(output.sourceMapEntries.count)")
                } else {
                    compilationError = output.errors.joined(separator: "\n")
                    debugStatus = "6:\(output.errors.first?.prefix(30) ?? "?")"
                    debugHistory += "E "
                    log("SVG compilation errors: \(output.errors)")
                }
            } else {
                // PDF rendering — traditional path
                debugStatus = "4:rendering(pdf)"
                debugHistory += "4pdf "
                log("Calling renderer.render()")
                let output = try await renderer.render(sourceText, options: options)
                debugStatus = "5:done,ok=\(output.isSuccess),sz=\(output.pdfData.count)"
                debugHistory += "5:\(output.pdfData.count) "
                log("renderer.render() completed, success: \(output.isSuccess), size: \(output.pdfData.count)")

                if output.isSuccess {
                    pdfData = output.pdfData
                    sourceMapEntries = output.sourceMapEntries
                    compilationWarnings = output.warnings
                    // Cache PDF for HTTP API access
                    DocumentRegistry.shared.cachePDF(output.pdfData, for: document.id)
                    debugStatus = "6:set,\(output.pdfData.count)b,map=\(output.sourceMapEntries.count)"
                    debugHistory += "6:ok "
                    log("PDF data set, size: \(output.pdfData.count), source map entries: \(output.sourceMapEntries.count)")
                } else {
                    compilationError = output.errors.joined(separator: "\n")
                    debugStatus = "6:\(output.errors.first?.prefix(30) ?? "?")"
                    debugHistory += "E "
                    log("Compilation errors: \(output.errors)")
                }
            }
        } catch {
            compilationError = error.localizedDescription
            debugStatus = "X:\(error)"
            debugHistory += "X:\(error) "
            log("Exception: \(error)")
        }

        isCompiling = false
        debugStatus = "F:pdf=\(pdfData?.count ?? 0)"
        debugHistory += "F:\(pdfData?.count ?? 0)"
        log("compile() finished")
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

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .insertCitation)) { _ in
                appState.showingCitationPicker = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .compileDocument)) { _ in
                onCompile()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showVersionHistory)) { _ in
                appState.showingVersionHistory = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleFocusMode)) { _ in
                appState.isFocusMode.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleAIAssistant)) { _ in
                withAnimation { appState.showingAIAssistant.toggle() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleCommentsSidebar)) { _ in
                withAnimation { appState.showingComments.toggle() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportPDF)) { _ in
                onExportPDF()
            }
            .onReceive(NotificationCenter.default.publisher(for: .printPDF)) { _ in
                onPrintPDF()
            }
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
        case .updateContent(let source, let title):
            if let source = source {
                updatedDoc.source = source
                document.source = source
            }
            if let title = title {
                updatedDoc.title = title
                document.title = title
            }
            updatedDoc.modifiedAt = Date()

        case .insertText(let position, let text):
            updatedDoc.insertText(text, at: position)
            document.insertText(text, at: position)

        case .deleteText(let start, let end):
            updatedDoc.deleteText(in: start..<end)
            document.deleteText(in: start..<end)

        case .replace(let search, let replacement, let all):
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

        case .addCitation(let citeKey, let bibtex):
            updatedDoc.bibliography[citeKey] = bibtex
            updatedDoc.modifiedAt = Date()
            document.addCitation(key: citeKey, bibtex: bibtex)

        case .removeCitation(let citeKey):
            updatedDoc.bibliography.removeValue(forKey: citeKey)
            updatedDoc.modifiedAt = Date()
            document.bibliography.removeValue(forKey: citeKey)
            document.modifiedAt = Date()

        case .updateMetadata(let title, let authors):
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

        NSLog("[Automation] Processed operation for document %@: %@", document.id.uuidString, operation.operationDescription)
    }
}

// MARK: - Preview

#Preview {
    ContentView(document: .constant(ImprintDocument()))
        .environment(AppState())
}
#endif // os(macOS)
