//
//  IOSContentView.swift
//  imprint-iOS
//
//  Main content view for imprint on iOS/iPadOS, wired to the shared
//  ImprintDocumentViewModel so iPhone/iPad get the same in-process Typst
//  compile pipeline as the desktop app.
//
//  - iPhone: full-screen editor, compile status in the toolbar
//  - iPad: editor + live PDF preview side by side
//

import SwiftUI
import OSLog
import ImpressLogging
import ImprintCore
import PublicationManagerCore

// MARK: - iOS Content View

struct IOSContentView: View {

    // MARK: - Properties

    /// The document being edited
    @Binding var document: ImprintDocument

    /// Shared compile/preview pipeline (same view model as macOS). LaTeX
    /// compilation is unavailable on iOS, so the platform capability is the
    /// unsupported implementation — Typst is the cross-platform path.
    @State private var vm = ImprintDocumentViewModel(latexCompiler: UnsupportedLaTeXCompiler())

    // Debounced recompile is owned by the compile controller (via `vm`).

    /// Whether to show the preview panel (iPad)
    @State private var showPreview = true

    /// Current editor selection
    @State private var selection: NSRange?

    /// One-shot go-to-line pulse for the editor (set by the outline).
    @State private var goToLine: Int?

    /// iPad: whether the outline column is shown.
    @State private var showOutlineColumn = false

    /// iPhone: whether the outline sheet is presented.
    @State private var showOutlineSheet = false

    /// Citation picker sheet visibility.
    @State private var showCitationPicker = false

    /// Error-detail popover visibility (compile status badge tap).
    @State private var showingErrorDetail = false

    /// Environment
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.undoManager) private var undoManager

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            if horizontalSizeClass == .regular && geometry.size.width > 600 {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        .toolbar {
            toolbarContent
        }
        .task {
            // First compile on open so the preview is populated.
            await compile()
        }
        .onChange(of: document.source) { _, _ in
            scheduleRecompile()
        }
        .sheet(isPresented: $showOutlineSheet) {
            NavigationStack {
                IOSDocumentOutlineView(
                    source: document.source,
                    format: document.format,
                    onNavigateToLine: { line in goToLine = line },
                    onDismiss: { showOutlineSheet = false }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showOutlineSheet = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showCitationPicker) {
            IOSCitationPickerView { picked in
                insertCitation(picked)
            }
        }
    }

    // MARK: - iPad Layout

    private var iPadLayout: some View {
        HStack(spacing: 0) {
            if showOutlineColumn {
                IOSDocumentOutlineView(
                    source: document.source,
                    format: document.format,
                    onNavigateToLine: { line in goToLine = line }
                )
                .frame(width: 260)

                Divider()
            }

            IOSSourceEditorView(
                text: $document.source,
                selection: $selection,
                goToLine: $goToLine,
                onInsertCitation: { showCitationPicker = true }
            )
            .frame(minWidth: 300)

            if showPreview {
                Divider()

                IOSPDFPreviewView(
                    pdfData: vm.pdfData,
                    isCompiling: vm.isCompiling
                )
                .frame(minWidth: 300)
            }
        }
    }

    // MARK: - iPhone Layout

    private var iPhoneLayout: some View {
        IOSSourceEditorView(
            text: $document.source,
            selection: $selection,
            goToLine: $goToLine,
            onInsertCitation: { showCitationPicker = true }
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Leading items
        ToolbarItemGroup(placement: .topBarLeading) {
            Text(document.title)
                .font(.headline)
        }

        // Trailing items
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Outline — persistent column on iPad, sheet on iPhone.
            Button {
                if horizontalSizeClass == .regular {
                    withAnimation { showOutlineColumn.toggle() }
                } else {
                    showOutlineSheet = true
                }
            } label: {
                Image(systemName: "list.bullet.indent")
            }
            .accessibilityIdentifier("toolbar.outlineButton")

            // Insert citation from the shared library.
            Button {
                showCitationPicker = true
            } label: {
                Image(systemName: "quote.opening")
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .accessibilityIdentifier("toolbar.citationButton")

            // Insert an Apple Pencil sketch. `SketchButton` owns the canvas
            // drawing state and its own presentation sheet.
            SketchButton { pngData in
                insertSketch(pngData)
            }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("toolbar.sketchButton")

            // Compile status — same glanceable badge as macOS.
            if let err = vm.compilationError, !err.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("toolbar.compileStatus")
                    .accessibilityValue("pdf=\(vm.pdfData?.count ?? 0)b")
                    .onTapGesture { showingErrorDetail = true }
                    .popover(isPresented: $showingErrorDetail) {
                        ScrollView {
                            Text(err)
                                .font(.system(.caption, design: .monospaced))
                                .padding()
                        }
                        .frame(minWidth: 280, maxWidth: 400, maxHeight: 300)
                        .presentationCompactAdaptation(.popover)
                    }
            } else if let pdf = vm.pdfData {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("toolbar.compileStatus")
                    .accessibilityValue("pdf=\(pdf.count)b")
            }

            // Compile button
            Button {
                Task { await compile() }
            } label: {
                if vm.isCompiling {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "hammer")
                }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityIdentifier("toolbar.compileButton")

            // Toggle preview (iPad only)
            if horizontalSizeClass == .regular {
                Button {
                    withAnimation {
                        showPreview.toggle()
                    }
                } label: {
                    Image(systemName: showPreview ? "rectangle.righthalf.inset.filled" : "rectangle.split.2x1")
                }
            }

            // More menu
            Menu {
                if let pdf = vm.pdfData {
                    ShareLink(
                        item: PDFExportItem(data: pdf, title: document.title),
                        preview: SharePreview(document.title, image: Image(systemName: "doc.richtext"))
                    ) {
                        Label("Export PDF", systemImage: "arrow.down.doc")
                    }
                } else {
                    Label("Export PDF (compile first)", systemImage: "arrow.down.doc")
                        .foregroundStyle(.secondary)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }

        // Bottom bar items
        ToolbarItemGroup(placement: .bottomBar) {
            // Undo/Redo — the source editor's UITextView participates in the
            // window's undo manager.
            HStack(spacing: 16) {
                Button {
                    undoManager?.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(undoManager?.canUndo != true)

                Button {
                    undoManager?.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(undoManager?.canRedo != true)
            }

            Spacer()

            // Typst formatting quick actions
            HStack(spacing: 16) {
                Button {
                    insertFormatting("*", "*")
                } label: {
                    Image(systemName: "bold")
                }
                .keyboardShortcut("b", modifiers: .command)

                Button {
                    insertFormatting("_", "_")
                } label: {
                    Image(systemName: "italic")
                }
                .keyboardShortcut("i", modifiers: .command)

                Button {
                    insertFormatting("`", "`")
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }

                // Insert citation — the touch-reachable twin of ⌘S (the
                // chassis-wide insert-citation shortcut), placed with the
                // formatting actions so it's thumb-distance while typing.
                Button {
                    showCitationPicker = true
                } label: {
                    Image(systemName: "at")
                }
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier("editor.insertCitation")
            }

            Spacer()
        }
    }

    // MARK: - Compile

    /// Snapshot inputs and run the shared compile pipeline.
    private func compile() async {
        // Capture everything before the async hop (CLAUDE.md: capture
        // @State/@Binding before async work).
        let inputs = CompileInputs(
            source: document.source,
            format: document.format,
            previewFormat: "pdf",
            documentID: document.id,
            documentTitle: document.title,
            latexEngine: "pdflatex",
            latexShellEscape: false,
            latexShowBoxWarnings: false
        )
        await vm.compile(inputs)
    }

    /// Debounced recompile while typing (800 ms of quiet). Timing + task
    /// lifetime are owned by the compile controller (via `vm`).
    private func scheduleRecompile() {
        vm.scheduleCompile(after: 800) {
            await compile()
        }
    }

    // MARK: - Actions

    /// Wrap the current selection in Typst markup (or append an empty pair).
    private func insertFormatting(_ prefix: String, _ suffix: String) {
        let src = document.source
        if let sel = selection,
           sel.location != NSNotFound,
           let range = Range(sel, in: src) {
            let selected = src[range]
            document.source.replaceSubrange(range, with: "\(prefix)\(selected)\(suffix)")
        } else {
            document.source.append("\(prefix)\(suffix)")
        }
    }

    /// Insert `text` at the current caret (UTF-16 offset), replacing any
    /// selected range, and move the caret to just after the inserted text.
    private func insertAtCursor(_ text: String) {
        let ns = document.source as NSString
        let insertRange: NSRange
        if let sel = selection, sel.location != NSNotFound, sel.location <= ns.length {
            insertRange = NSRange(location: sel.location, length: min(sel.length, ns.length - sel.location))
        } else {
            insertRange = NSRange(location: ns.length, length: 0)
        }
        document.source = ns.replacingCharacters(in: insertRange, with: text)
        // Place the caret after the inserted text so the editor scrolls to it.
        let caret = insertRange.location + (text as NSString).length
        selection = NSRange(location: caret, length: 0)
    }

    /// Insert a Typst `@citekey` reference and record a BibTeX stub so the
    /// key survives a save round-trip through `bibliography.bib`.
    private func insertCitation(_ picked: PickedCitation) {
        if document.bibliography[picked.citeKey] == nil {
            document.bibliography[picked.citeKey] = picked.bibtexStub
        }
        insertAtCursor("@\(picked.citeKey)")
        Logger.imbibIntegration.infoCapture(
            "Inserted citation @\(picked.citeKey) at \(selection?.location ?? -1)",
            category: "citation"
        )
    }

    /// Save a sketch PNG into the manuscript working directory's `assets/`
    /// and insert a Typst `#image(...)` reference at the caret.
    private func insertSketch(_ pngData: Data) {
        // Capture value types before the async hop (CLAUDE.md).
        let docID = document.id
        let byteCount = pngData.count
        Task {
            let service = SketchInsertionService()
            do {
                let base = try ManuscriptWorkingDirectory().manuscriptDirectory(for: docID)
                let relativePath = try await service.saveSketch(pngData, to: base)
                let code = await service.generateTypstImageCode(path: relativePath, width: "80%")
                await MainActor.run {
                    insertAtCursor(code)
                    Logger.sketch.infoCapture(
                        "Inserted sketch (\(byteCount)b) → \(relativePath)",
                        category: "sketch"
                    )
                }
            } catch {
                Logger.sketch.errorCapture(
                    "Failed to save sketch: \(error.localizedDescription)",
                    category: "sketch"
                )
            }
        }
    }
}

// MARK: - PDF export wrapper

/// Transferable wrapper so ShareLink exports the compiled PDF with a
/// sensible filename.
import CoreTransferable
import UniformTypeIdentifiers

struct PDFExportItem: Transferable {
    let data: Data
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { item in
            item.data
        }
        .suggestedFileName { item in
            "\(item.title.isEmpty ? "Untitled" : item.title).pdf"
        }
    }
}

// MARK: - Preview

#Preview("iPhone") {
    NavigationStack {
        IOSContentView(document: .constant(ImprintDocument()))
    }
}

#Preview("iPad") {
    NavigationStack {
        IOSContentView(document: .constant(ImprintDocument()))
    }
}
