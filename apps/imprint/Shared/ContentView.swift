import SwiftUI
import ImprintCore

/// Main content view for an imprint document
struct ContentView: View {
    @Binding var document: ImprintDocument
    @EnvironmentObject var appState: AppState

    @State private var cursorPosition: Int = 0
    @State private var pdfData: Data?
    @State private var sourceMapEntries: [SourceMapEntry] = []
    @State private var isCompiling = false
    @State private var compilationError: String?
    @State private var compilationWarnings: [String] = []
    @State private var debugStatus: String = "idle"
    @State private var debugHistory: String = ""

    /// Comment service for this document
    @StateObject private var commentService = CommentService()

    /// Shared Typst renderer instance
    private let renderer = TypstRenderer()

    var body: some View {
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
                .help("Compile (Cmd+B)")
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
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("debug.pdfSize")
                Text(debugHistory)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("debug.history")
                Text("err=\(compilationError?.prefix(100) ?? "none")")
                    .font(.caption2)
                    .foregroundColor(.red)
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
        .onReceive(NotificationCenter.default.publisher(for: .insertCitation)) { _ in
            appState.showingCitationPicker = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .compileDocument)) { _ in
            Task { await compile() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showVersionHistory)) { _ in
            appState.showingVersionHistory = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleFocusMode)) { _ in
            appState.isFocusMode.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleAIAssistant)) { _ in
            withAnimation {
                appState.showingAIAssistant.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCommentsSidebar)) { _ in
            withAnimation {
                appState.showingComments.toggle()
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
    }

    @ViewBuilder
    private var editorView: some View {
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
                .frame(minWidth: 300)

                PDFPreviewView(
                    pdfData: pdfData,
                    isCompiling: isCompiling,
                    sourceMapEntries: sourceMapEntries,
                    cursorPosition: cursorPosition
                )
                .frame(minWidth: 300)
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

    /// Insert text at the current cursor position
    private func insertTextAtCursor(_ text: String) {
        let position = min(cursorPosition, document.source.count)
        let index = document.source.index(document.source.startIndex, offsetBy: position)
        document.source.insert(contentsOf: text, at: index)
        cursorPosition = position + text.count
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

        // Get source before any async work
        let sourceText = document.source
        debugStatus = "2:src=\(sourceText.count)ch"
        debugHistory += "2:\(sourceText.count) "
        log("Source text length: \(sourceText.count)")

        do {
            log("Creating RenderOptions")
            debugStatus = "3:options"
            debugHistory += "3 "
            let options = RenderOptions(
                pageSize: .a4,
                isDraft: false
            )

            debugStatus = "4:rendering"
            debugHistory += "4 "
            log("Calling renderer.render()")
            let output = try await renderer.render(sourceText, options: options)
            debugStatus = "5:done,ok=\(output.isSuccess),sz=\(output.pdfData.count)"
            debugHistory += "5:\(output.pdfData.count) "
            log("renderer.render() completed, success: \(output.isSuccess), size: \(output.pdfData.count)")

            if output.isSuccess {
                pdfData = output.pdfData
                sourceMapEntries = output.sourceMapEntries
                compilationWarnings = output.warnings
                debugStatus = "6:set,\(output.pdfData.count)b,map=\(output.sourceMapEntries.count)"
                debugHistory += "6:ok "
                log("PDF data set, size: \(output.pdfData.count), source map entries: \(output.sourceMapEntries.count)")
            } else {
                compilationError = output.errors.joined(separator: "\n")
                debugStatus = "6:\(output.errors.first?.prefix(30) ?? "?")"
                debugHistory += "E "
                log("Compilation errors: \(output.errors)")
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
                .foregroundColor(isSelected ? .primary : .secondary)
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


// MARK: - Preview

#Preview {
    ContentView(document: .constant(ImprintDocument()))
        .environmentObject(AppState())
}
