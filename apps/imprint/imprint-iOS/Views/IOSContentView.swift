//
//  IOSContentView.swift
//  imprint-iOS
//
//  Main content view for imprint on iOS/iPadOS, wired to the shared
//  ImprintDocumentViewModel so iPhone/iPad get the same in-process Typst
//  compile pipeline as the desktop app.
//
//  - iPhone: Source / Preview segmented control over one full-width surface
//  - iPad: editor + live preview side by side
//
//  Which preview surface appears (compiled PDF, live Markdown, or none at all)
//  is derived from `DocumentFormat.PreviewKind` via the shared
//  `IOSManuscriptPreviewView` — never from a hardcoded format test here.
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

    /// Whether to show the preview panel (regular width — side-by-side).
    /// Persisted like the macOS Source tab's `manuscript.sourceTab.showPreview`,
    /// so the choice survives relaunch on both platforms.
    @AppStorage("imprint.editor.showPreview") private var showPreview = true

    /// Which surface fills the screen in compact width (iPhone). The preview
    /// pane can't sit beside the editor there, so the two share the screen the
    /// way imbib-iOS's manuscript detail does: a segmented control.
    @AppStorage("imprint.editor.compactPane") private var compactPane: EditorPane = .source

    /// The two full-width surfaces available in compact width.
    enum EditorPane: String, CaseIterable, Identifiable {
        case source = "Source"
        case preview = "Preview"
        var id: String { rawValue }
    }

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

    /// Throughline pane visibility (C1). A SHEET rather than a third
    /// `EditorPane` case: the throughline is an inspector — macOS mounts it as a
    /// side-panel column beside the source, not as a replacement for it — and a
    /// third pane case would have to fight two things that are already load
    /// bearing here, the two-state Source↔Preview swipe (`paneSwipe` hard-assigns
    /// a destination from the drag direction) and the persisted
    /// `imprint.editor.compactPane` choice, which would strand a user in a pane
    /// the picker hides for a plain-text document.
    @State private var showThroughline = false

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
        .onChange(of: document.source) { oldSource, newSource in
            // The host loads the body from the store ASYNCHRONOUSLY, so the
            // `.task` above often runs against an empty buffer and compiles
            // nothing. When the real body arrives, compile it NOW rather than
            // waiting out the typing debounce — otherwise opening a document
            // and switching straight to Preview shows an empty pane for the
            // better part of a second, which reads as "it isn't compiling".
            if oldSource.isEmpty, !newSource.isEmpty {
                Task { await compile() }
            } else {
                scheduleRecompile()
            }
        }
        .onChange(of: compactPane) { _, newPane in
            // Revealing the preview on iPhone with nothing compiled yet (e.g.
            // the first compile failed, or the document was just opened) should
            // not show an empty pane — kick a compile immediately.
            if newPane == .preview, vm.pdfData == nil, !vm.isCompiling {
                Task { await compile() }
            }
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
        // The throughline pane — THE pane, not an iOS copy of it: the same
        // `ThroughlinePaneView` macOS's side panel mounts, moved to
        // `Shared/Views/` in C1. Presented here rather than at the navigation
        // root (where the citation sheet lives) because it is bound to the
        // document this editor is holding; a deep link with no editor open would
        // have no document to show.
        .sheet(isPresented: $showThroughline) {
            NavigationStack {
                ThroughlinePaneView(
                    document: $document,
                    onNavigateToSection: { key in
                        // macOS jumps by character offset (`context.jumpToChar`);
                        // the iOS editor's primitive is a line, so the key is
                        // resolved against the source's own headings — the same
                        // `ThroughlineText.sectionKey` slug the anchors use, so a
                        // chip can never point somewhere the anchor does not.
                        if let line = lineOfSection(key: key) {
                            goToLine = line
                        }
                        showThroughline = false
                    })
                    .navigationTitle("Throughline")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showThroughline = false }
                                .accessibilityIdentifier("throughline.done")
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// The 1-based line of the heading whose section key is `key`, or nil when
    /// the anchor no longer resolves (which the pane already renders as a red
    /// `broken` chip — so returning nil leaves the editor where it is rather
    /// than jumping to line 1).
    private func lineOfSection(key: String) -> Int? {
        let lines = document.source.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let title: String?
            switch document.format {
            case .latex:
                // \section{Title} / \subsection{Title}
                guard let open = trimmed.firstIndex(of: "{"),
                      trimmed.hasPrefix("\\"),
                      let close = trimmed.lastIndex(of: "}") else { continue }
                title = String(trimmed[trimmed.index(after: open)..<close])
            default:
                // Typst / markdown headings: one or more `=` (or `#`) then text.
                guard trimmed.hasPrefix("=") || trimmed.hasPrefix("#") else { continue }
                title = trimmed.drop { $0 == "=" || $0 == "#" }
                    .trimmingCharacters(in: .whitespaces)
            }
            guard let title, !title.isEmpty else { continue }
            if ThroughlineText.sectionKey(forHeading: title) == key {
                return index + 1
            }
        }
        return nil
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

            sourceEditor
                .frame(minWidth: 300)

            // A format with no rendered counterpart (plain text) gets no
            // preview column at all — `hasPreview` is the single gate, here
            // and on the toolbar affordance below.
            if showPreview && document.format.hasPreview {
                Divider()

                previewSurface
                    .frame(minWidth: 300)
            }
        }
    }

    // MARK: - iPhone Layout

    private var iPhoneLayout: some View {
        VStack(spacing: 0) {
            if document.format.hasPreview {
                Picker("View", selection: $compactPane) {
                    ForEach(EditorPane.allCases) { pane in
                        Text(pane.rawValue).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityIdentifier("editor.panePicker")

                Divider()
            }

            switch effectiveCompactPane {
            case .source:
                sourceEditor
            case .preview:
                previewSurface
            }
        }
        // Swipe left from Source → Preview, right from Preview → Source.
        //
        // A DragGesture, not a TabView: the source pane is a UITextView whose
        // own pan gestures (selection, scrolling) must keep working, so this
        // only claims horizontal drags that clearly beat the vertical
        // component. `minimumDistance` keeps a tap from ever registering.
        .gesture(paneSwipe, isEnabled: document.format.hasPreview)
    }

    /// Horizontal swipe between the two compact panes.
    private var paneSwipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                // Must be decisively horizontal, or a diagonal scroll would
                // flip the pane out from under the reader.
                guard abs(dx) > 60, abs(dx) > abs(dy) * 2 else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    if dx < 0 {
                        compactPane = .preview
                    } else {
                        compactPane = .source
                    }
                }
            }
    }

    /// A remembered `.preview` choice must not survive into a format that has
    /// no preview (plain text) — the picker is hidden there, so the user would
    /// have no way back to the source.
    private var effectiveCompactPane: EditorPane {
        document.format.hasPreview ? compactPane : .source
    }

    // MARK: - Surfaces (shared by both layouts)

    private var sourceEditor: some View {
        IOSSourceEditorView(
            text: $document.source,
            selection: $selection,
            goToLine: $goToLine,
            format: document.format,
            onInsertCitation: { showCitationPicker = true },
            onCiteKeyLongPress: { occurrence in inspectCiteKey(occurrence.key) }
        )
    }

    // MARK: - Citation inspection
    //
    // macOS: hover a cite key → preview popover → "Open in paper panel".
    // iOS: long-press a cite key → a paper sheet. Same lookup, same exits, one
    // gesture instead of hover-then-click.
    //
    // The gesture does NOT present the sheet itself — it posts `.inspectCiteKey`,
    // exactly as `imprint://inspect/citation/{key}` does, and the library view
    // (the navigation root) presents. One presenter, one code path: a citation
    // inspected by an agent and one inspected by a finger are the same event,
    // and the deep link works even when no editor is open.

    private func inspectCiteKey(_ citeKey: String) {
        Logger.imbibIntegration.infoCapture(
            "long press requested inspection of cite key '\(citeKey)'",
            category: "citation"
        )
        NotificationCenter.default.post(
            name: .inspectCiteKey,
            object: nil,
            userInfo: ["citeKey": citeKey]
        )
    }

    /// The preview. `IOSManuscriptPreviewView` picks PDF vs. live Markdown vs.
    /// nothing from `document.format.previewKind`.
    private var previewSurface: some View {
        IOSManuscriptPreviewView(
            format: document.format,
            source: document.source,
            pdfData: vm.pdfData,
            isCompiling: vm.isCompiling,
            compilationError: vm.compilationError
        )
        .accessibilityIdentifier("editor.preview")
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

            // Throughline (ADR-0016) — the narrative spine. Same glyph the
            // macOS side panel registers, so the two hosts are recognisably the
            // same surface. Unconditional: the pane's own empty state is the
            // opt-in create affordance, and hiding the button would leave iOS
            // with no way to create one at all.
            Button {
                showThroughline = true
            } label: {
                Image(
                    systemName:
                        "point.bottomleft.forward.to.point.topright.scurvepath")
            }
            .accessibilityIdentifier("toolbar.throughlineButton")
            .accessibilityLabel("Throughline")

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

            // Toggle preview — present in BOTH size classes, and gated only on
            // whether the format HAS a preview (plain text has none). Regular
            // width toggles the side-by-side column; compact width flips the
            // full-width surface, exactly like the outline button above
            // (column on iPad, sheet on iPhone).
            if document.format.hasPreview {
                Button {
                    withAnimation { togglePreview() }
                } label: {
                    Image(systemName: previewToggleSymbol)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .accessibilityIdentifier("toolbar.previewButton")
                .accessibilityLabel(isPreviewVisible ? "Hide Preview" : "Show Preview")
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

    // MARK: - Preview affordance

    /// Whether a preview is on screen right now, in either size class.
    private var isPreviewVisible: Bool {
        horizontalSizeClass == .regular ? showPreview : effectiveCompactPane == .preview
    }

    private var previewToggleSymbol: String {
        if horizontalSizeClass == .regular {
            return showPreview ? "rectangle.righthalf.inset.filled" : "rectangle.split.2x1"
        }
        return effectiveCompactPane == .preview ? "doc.text" : "doc.richtext"
    }

    private func togglePreview() {
        if horizontalSizeClass == .regular {
            showPreview.toggle()
        } else {
            compactPane = effectiveCompactPane == .preview ? .source : .preview
        }
    }

    // MARK: - Compile

    /// Snapshot inputs and run the shared compile pipeline.
    private func compile() async {
        // Only formats whose preview IS a compiled artifact have anything to
        // compile — Markdown renders live from the buffer, plain text has no
        // preview at all (same guard as ManuscriptEditorSession.scheduleCompile).
        guard document.format.requiresCompile else { return }
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
            latexShowBoxWarnings: false,
            // Without this, ANY `image("figures/…")` fails the whole compile on
            // iOS. Same root the macOS session passes
            // (ManuscriptEditorSession.makeCompileInputs) and the same root the
            // sketch inserter writes into, so relative paths resolve.
            figuresRoot: ManuscriptFiguresDirectory.manuscriptRoot(for: document.id).path
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
                // Write into the SAME root that goes into the compile as
                // `figuresRoot`, so the inserted `#image("assets/…")` resolves.
                // (It used to land under ManuscriptWorkingDirectory, a
                // different directory the Typst compile never sees.)
                let base = ManuscriptFiguresDirectory.manuscriptRoot(for: docID)
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
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
