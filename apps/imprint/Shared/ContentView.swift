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

    /// Shared Typst renderer instance
    private let renderer = TypstRenderer()

    var body: some View {
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

                // Share button
                Button {
                    // TODO: Show share sheet
                } label: {
                    Image(systemName: "person.2")
                }
                .help("Share Document")
                .accessibilityIdentifier("toolbar.shareButton")

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
    }

    @ViewBuilder
    private var editorView: some View {
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
                    cursorPosition: $cursorPosition
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
                cursorPosition: $cursorPosition
            )
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
