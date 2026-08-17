//
//  IOSManuscriptDetailView.swift
//  imbib-iOS
//
//  GUI-meld Phase 8. iOS manuscript detail: an editable body (reusing the
//  shared PMC `IOSSourceEditorView`) plus an Info tab with metadata and a
//  revisions list. Body edits are debounced back into the unified store via
//  `RustStoreAdapter.setManuscriptBody`, guarded by the last-loaded content
//  hash (compare-and-set) so a concurrent writer in imprint can't be
//  silently clobbered.
//
//  2026-07-23: Preview tab (in-process Typst compile via the shared
//  ManuscriptCompileController + IOSPDFPreviewView — the pipeline existed and
//  was iOS-capable but was never wired here), a citation picker inserting
//  `@citeKey` from the imbib library (ManuscriptEditorEnvironment.citationSearch
//  seam), and a live "Cited Papers" section in Info.
//

// BibliographyRow arrives via PMC's @_exported ImbibRustCore; cite-key
// extraction via PMC's ManuscriptCitationKeys — no direct ImprintCore /
// ImbibRustCore product links needed on this target.
import SwiftUI
import PublicationManagerCore
import OSLog

struct IOSManuscriptDetailView: View {

    let manuscriptID: UUID

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    private enum Tab: String, CaseIterable, Identifiable {
        case editor = "Editor"
        case preview = "Preview"
        case info = "Info"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .editor

    // Loaded detail + editor buffer.
    @State private var detail: ManuscriptDetail?
    @State private var body_ = ""
    @State private var selection: NSRange?
    @State private var lastHash: String?
    /// Document heads last seen — the base the next commit diffs against.
    @State private var lastHeads: [String] = []
    @State private var hasLoaded = false

    // Revisions (Info tab).
    @State private var revisions: [ManuscriptRevisionRow] = []

    // Compile/preview. The controller is the shared cross-platform compile
    // core (Typst in-process; LaTeX reports unsupported on iOS).
    @State private var compiler = ManuscriptCompileController(
        latexCompiler: UnsupportedLaTeXCompiler()
    )
    @State private var lastCompiledText: String?

    // Citation picker.
    @State private var showCitationPicker = false

    // Debouncer.
    @State private var debounceTask: Task<Void, Never>?
    private static let debounceInterval: Duration = .milliseconds(400)

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch tab {
                case .editor:
                    editorPane
                case .preview:
                    previewPane
                case .info:
                    infoPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(detail?.title ?? "Manuscript")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if tab == .editor {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCitationPicker = true
                    } label: {
                        Label("Insert Citation", systemImage: "at.badge.plus")
                    }
                    .accessibilityIdentifier("manuscript.insertCitation")
                }
            }
        }
        .sheet(isPresented: $showCitationPicker) {
            IOSCitationPickerSheet { citeKey in
                insertCitation(citeKey)
            }
        }
        .task(id: manuscriptID) { await load() }
        .onChange(of: store.dataVersion) { _, _ in
            // Metadata/revisions may change out from under us (imprint edits,
            // new revision snapshots). Refresh the read-only surfaces, but do
            // NOT stomp the editor buffer while the user is typing.
            if let d = store.getManuscriptDetail(id: manuscriptID) {
                detail = d
            }
            revisions = store.listManuscriptRevisions(manuscriptID: manuscriptID)
        }
        .onChange(of: body_) { _, newValue in
            guard hasLoaded else { return }
            scheduleSave(text: newValue)
            // Keep the preview warm while it's visible: recompile after the
            // shared debounce policy instead of waiting for a tab flip.
            if tab == .preview {
                compiler.scheduleCompile(after: 700) {
                    await compileNow()
                }
            }
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .preview && lastCompiledText != body_ {
                Task { await compileNow() }
            }
        }
        .onDisappear {
            debounceTask?.cancel()
            if hasLoaded { saveNow(text: body_) }
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editorPane: some View {
        if hasLoaded {
            if detail?.bodyIsBlobRef == true {
                ContentUnavailableView(
                    "Large Manuscript",
                    systemImage: "doc.badge.gearshape",
                    description: Text("This manuscript's body is stored as a blob and is best edited in imprint.")
                )
            } else {
                IOSSourceEditorView(
                    text: $body_,
                    selection: $selection,
                    format: manuscriptFormat,
                    onInsertCitation: { showCitationPicker = true }
                )
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Preview

    /// The manuscript's format, resolved the same way the macOS editor session
    /// resolves it: the stored value when it's one we know, else detected from
    /// the body/title. Drives syntax highlighting, the preview surface, and the
    /// compile branch — all from this one property.
    private var manuscriptFormat: DocumentFormat {
        if let stored = detail?.format, let known = DocumentFormat(rawValue: stored) {
            return known
        }
        return DocumentFormat.detect(from: body_, title: detail?.title)
    }

    @ViewBuilder
    private var previewPane: some View {
        ZStack(alignment: .bottom) {
            // PreviewKind decides PDF vs. live Markdown vs. nothing.
            IOSManuscriptPreviewView(
                format: manuscriptFormat,
                source: body_,
                pdfData: compiler.pdfData,
                isCompiling: compiler.isCompiling
            )
            if let error = compiler.compilationError, !error.isEmpty {
                Text(error)
                    .font(.caption.monospaced())
                    .lineLimit(4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                    .padding(8)
            }
        }
    }

    private func compileNow() async {
        let source = body_
        let format = manuscriptFormat
        // Markdown renders live from the buffer; plain text has no preview.
        guard format.requiresCompile else { return }
        let inputs = CompileInputs(
            source: source,
            format: format,
            previewFormat: "pdf",
            documentID: manuscriptID,
            documentTitle: detail?.title ?? "Manuscript",
            latexEngine: "",
            latexShellEscape: false,
            latexShowBoxWarnings: false,
            figuresRoot: ManuscriptFiguresDirectory.manuscriptRoot(for: manuscriptID).path
        )
        await compiler.compile(inputs)
        lastCompiledText = source
    }

    // MARK: - Citations

    /// Insert `@citeKey` at the caret (or append when there is no selection),
    /// with sensible spacing on either side.
    private func insertCitation(_ citeKey: String) {
        let insertion = "@\(citeKey)"
        let ns = body_ as NSString
        let location = min(selection?.location ?? ns.length, ns.length)

        var text = insertion
        if location > 0 {
            let prev = ns.substring(with: NSRange(location: location - 1, length: 1))
            if !prev.isEmpty && prev.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                && prev != "(" && prev != "[" {
                text = " " + text
            }
        }
        body_ = ns.replacingCharacters(in: NSRange(location: location, length: 0), with: text)
        selection = NSRange(location: location + (text as NSString).length, length: 0)
    }

    /// Cite keys currently referenced by the editor buffer, resolved against
    /// the library. Computed live from the source (canonical Rust scanner) —
    /// no stored state to go stale.
    private var citedRows: [(key: String, row: BibliographyRow?)] {
        let keys = ManuscriptCitationKeys.extract(from: body_)
        guard !keys.isEmpty else { return [] }
        let search = ManuscriptEditorEnvironment.shared.citationSearch
        return keys.map { ($0, search?.findByCiteKey($0)) }
    }

    // MARK: - Info

    @ViewBuilder
    private var infoPane: some View {
        if let d = detail {
            List {
                Section("Metadata") {
                    labeledRow("Status", d.status)
                    if !d.authors.isEmpty {
                        labeledRow("Authors", d.authors.joined(separator: ", "))
                    }
                    labeledRow("Format", d.format.isEmpty ? "typst" : d.format)
                    if let journal = d.journalTarget, !journal.isEmpty {
                        labeledRow("Journal Target", journal)
                    }
                    if !d.topicTags.isEmpty {
                        labeledRow("Topics", d.topicTags.joined(separator: ", "))
                    }
                    if let modified = d.bodyModifiedAt, !modified.isEmpty {
                        labeledRow("Body Modified", modified)
                    }
                }

                citedPapersSection

                Section("Revisions") {
                    if revisions.isEmpty {
                        Text("No revisions yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(revisions, id: \.id) { rev in
                            revisionRow(rev)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var citedPapersSection: some View {
        let cited = citedRows
        if !cited.isEmpty {
            Section("Cited Papers (\(cited.count))") {
                ForEach(cited, id: \.key) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        if let row = entry.row {
                            Text(row.title)
                                .font(.subheadline)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Text("@\(entry.key)")
                                    .font(.caption.monospaced())
                                if let year = row.year {
                                    Text(String(year))
                                }
                                Text(row.authorString)
                                    .lineLimit(1)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            Label {
                                Text("@\(entry.key) — not in library")
                                    .font(.caption.monospaced())
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func revisionRow(_ rev: ManuscriptRevisionRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(rev.revisionTag)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let reason = rev.snapshotReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 8) {
                Text(Date(timeIntervalSince1970: TimeInterval(rev.dateCreated) / 1000.0),
                     style: .date)
                if let words = rev.wordCount {
                    Text("\(words) words")
                }
                if !rev.author.isEmpty {
                    Text(rev.author)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Data

    private func load() async {
        guard let d = store.getManuscriptDetail(id: manuscriptID) else {
            Logger.library.warningCapture(
                "IOSManuscriptDetailView: manuscript \(manuscriptID) not found",
                category: "manuscripts")
            return
        }
        detail = d
        body_ = d.bodyContent
        lastHash = d.bodyContentHash
        lastHeads = store.manuscriptCollabHeads(id: manuscriptID)
        revisions = store.listManuscriptRevisions(manuscriptID: manuscriptID)
        hasLoaded = true
    }

    private func scheduleSave(text: String) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: Self.debounceInterval)
                guard !Task.isCancelled else { return }
                saveNow(text: text)
            } catch is CancellationError {
                // Normal — superseded by a newer keystroke.
            } catch { }
        }
    }

    private func saveNow(text: String) {
        // ADR-0027: commit against the heads we last saw; the document merges
        // any edits made elsewhere (imprint, the Mac) with ours, and the
        // buffer adopts the merged text — nothing is overwritten either way.
        guard let outcome = store.commitManuscriptBody(
            id: manuscriptID, body: text, baseHeads: lastHeads
        ) else { return }
        lastHeads = outcome.heads
        lastHash = outcome.bodyHash
        if outcome.mergedExternal, body_ == text {
            Logger.library.infoCapture(
                "IOSManuscriptDetailView: merged external edits into \(manuscriptID)",
                category: "manuscripts")
            body_ = outcome.body
        }
    }
}

// MARK: - Citation Picker Sheet

/// Searchable list over the imbib library (citation seam); tapping a row
/// inserts its cite key into the manuscript. Shared-seam twin of the macOS
/// inline citation palette, shaped for touch.
struct IOSCitationPickerSheet: View {

    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [BibliographyRow] = []

    private var citationSearch: (any ManuscriptCitationSearching)? {
        ManuscriptEditorEnvironment.shared.citationSearch
    }

    var body: some View {
        NavigationStack {
            Group {
                if citationSearch == nil {
                    ContentUnavailableView(
                        "No Library",
                        systemImage: "books.vertical",
                        description: Text("Citation search is unavailable.")
                    )
                } else if results.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results, id: \.id) { row in
                        Button {
                            onPick(row.citeKey)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(.subheadline)
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    Text("@\(row.citeKey)")
                                        .font(.caption.monospaced())
                                    if let year = row.year {
                                        Text(String(year))
                                    }
                                    Text(row.authorString)
                                        .lineLimit(1)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Insert Citation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .searchable(text: $query, prompt: "Search library")
        .onChange(of: query) { _, newValue in
            results = citationSearch?.search(newValue, limit: 50) ?? []
        }
    }
}
