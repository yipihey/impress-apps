import SwiftUI

/// Main content view for an imprint document
struct ContentView: View {
    @Binding var document: ImprintDocument
    @EnvironmentObject var appState: AppState

    @State private var cursorPosition: Int = 0
    @State private var pdfData: Data?
    @State private var isCompiling = false
    @State private var compilationError: String?

    var body: some View {
        NavigationSplitView {
            // Sidebar: Document outline
            DocumentOutlineView(source: document.source)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            // Main editor area
            editorView
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Edit mode picker
                Picker("Mode", selection: $appState.editMode) {
                    Image(systemName: "doc.richtext").tag(EditMode.directPdf)
                    Image(systemName: "rectangle.split.2x1").tag(EditMode.splitView)
                    Image(systemName: "doc.text").tag(EditMode.textOnly)
                }
                .pickerStyle(.segmented)
                .help("Edit Mode (Tab to cycle)")

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

                // Citation button
                Button {
                    appState.showingCitationPicker = true
                } label: {
                    Image(systemName: "quote.opening")
                }
                .help("Insert Citation (Cmd+Shift+K)")

                // Share button
                Button {
                    // TODO: Show share sheet
                } label: {
                    Image(systemName: "person.2")
                }
                .help("Share Document")
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
                cursorPosition: $cursorPosition
            )

        case .splitView:
            HSplitView {
                SourceEditorView(
                    source: $document.source,
                    cursorPosition: $cursorPosition
                )
                .frame(minWidth: 300)

                PDFPreviewView(pdfData: pdfData, isCompiling: isCompiling)
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

    private func compile() async {
        isCompiling = true
        compilationError = nil

        do {
            // TODO: Call Rust renderer via ImprintCore
            // For now, just simulate compilation
            try await Task.sleep(nanoseconds: 500_000_000)

            // Placeholder PDF data
            pdfData = createPlaceholderPDF()
        } catch {
            compilationError = error.localizedDescription
        }

        isCompiling = false
    }

    private func createPlaceholderPDF() -> Data {
        // Create a minimal placeholder PDF
        let pdfContent = """
        %PDF-1.4
        1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
        3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >> endobj
        xref
        0 4
        0000000000 65535 f
        0000000009 00000 n
        0000000058 00000 n
        0000000115 00000 n
        trailer << /Size 4 /Root 1 0 R >>
        startxref
        193
        %%EOF
        """
        return pdfContent.data(using: .utf8) ?? Data()
    }
}

// MARK: - Preview

#Preview {
    ContentView(document: .constant(ImprintDocument()))
        .environmentObject(AppState())
}
