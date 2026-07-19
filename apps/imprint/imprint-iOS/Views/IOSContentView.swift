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

// MARK: - iOS Content View

struct IOSContentView: View {

    // MARK: - Properties

    /// The document being edited
    @Binding var document: ImprintDocument

    /// Shared compile/preview pipeline (same view model as macOS).
    @State private var vm = ImprintDocumentViewModel()

    /// Debounced recompile scheduled after edits.
    @State private var recompileTask: Task<Void, Never>?

    /// Whether to show the preview panel (iPad)
    @State private var showPreview = true

    /// Current editor selection
    @State private var selection: NSRange?

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
    }

    // MARK: - iPad Layout

    private var iPadLayout: some View {
        HStack(spacing: 0) {
            IOSSourceEditorView(
                text: $document.source,
                selection: $selection
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
            selection: $selection
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

    /// Debounced recompile while typing (800 ms of quiet).
    private func scheduleRecompile() {
        recompileTask?.cancel()
        recompileTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
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
