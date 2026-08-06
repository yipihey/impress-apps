#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  ManuscriptSourceTab.swift
//  PublicationManagerCore
//
//  The Source tab (GUI-meld plan §4): imprint's editor stack hosted in the
//  chassis detail pane, bound to a ManuscriptEditorSession. Editor on the
//  left; an optional live compiled-PDF preview on the right (default on, ≈
//  imprint's old split-editor mode). A compile-status strip and a non-modal
//  conflict banner frame it. The session lives in the registry OUTSIDE the
//  view tree, so this view carries NO `.id()` and survives tab/selection
//  switches without losing the buffer, undo stack, or an in-flight compile.

import SwiftUI
import PDFKit
import ImpressSyntaxHighlight
import ImprintCore  // SourceMapEntry / SourceMapUtils — source↔preview sync

public struct ManuscriptSourceTab: View {

    @State private var session: ManuscriptEditorSession
    @AppStorage("manuscript.sourceTab.showPreview") private var showPreview = true
    @AppStorage("manuscript.sourceTab.showOutline") private var showOutline = false
    @AppStorage("manuscript.sourceTab.showComments") private var showComments = false
    @AppStorage("manuscript.sourceTab.showInspector") private var showInspector = false
    /// The id of the currently-selected flanking-inspector panel.
    @AppStorage("manuscript.sourceTab.inspectorPanel") private var inspectorPanelID = ""
    /// Whether the compiler-diagnostics popover is up.
    @State private var showDiagnosticsPanel = false

    /// Host-contributed flanking panels (imprint's AI/Throughline/Veusz/Paper).
    /// Empty in imbib → no inspector.
    private var sidePanels: [any ManuscriptSidePanel] {
        ManuscriptEditorEnvironment.shared.sidePanels
    }

    public init(session: ManuscriptEditorSession) {
        _session = State(initialValue: session)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if session.conflict != nil { conflictBanner }
            editorSplit
            compileStrip
        }
    }

    @ViewBuilder
    private var editorSplit: some View {
        HSplitView {
            if showOutline {
                ManuscriptOutlineRail(
                    source: session.source,
                    format: session.format,
                    onJump: { charOffset in session.cursorPosition = charOffset }
                )
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 300)
            }
            editor
                .frame(minWidth: 320)
            if showComments {
                ManuscriptCommentsColumn(session: session)
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            }
            // Plain text has no rendered state — the preview column would be
            // permanently empty, so it is not offered at all.
            if showPreview, session.format.previewKind != .none {
                previewPane
                    .frame(minWidth: 280)
            }
            if showInspector, !sidePanels.isEmpty {
                inspectorColumn
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
            }
        }
        .task(id: session.manuscriptID) {
            // The editor's cite-key click posts .openPaperPanel; auto-open the
            // inspector on the Paper panel when it fires (if the host provides
            // one).
            guard sidePanels.contains(where: { $0.id == "paper" }) else { return }
            for await _ in NotificationCenter.default
                .notifications(named: .openPaperPanel).map({ _ in () }) {
                inspectorPanelID = "paper"
                showInspector = true
            }
        }
    }

    private var editor: some View {
        SourceEditorView(
            source: $session.source,
            cursorPosition: $session.cursorPosition,
            syntaxMode: session.format,
            highlight: session.highlightRequest,
            onSelectionChange: { _, range in session.selectedRange = range }
        )
    }

    // MARK: Flanking inspector (host-contributed panels)

    @ViewBuilder
    private var inspectorColumn: some View {
        let panels = sidePanels
        let selected = panels.first(where: { $0.id == inspectorPanelID }) ?? panels.first
        VStack(spacing: 0) {
            if panels.count > 1 {
                Picker("", selection: Binding(
                    get: { selected?.id ?? "" },
                    set: { inspectorPanelID = $0 }
                )) {
                    ForEach(panels, id: \.id) { panel in
                        Label(panel.label, systemImage: panel.systemImage).tag(panel.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .labelsHidden()
                .padding(.horizontal, 8).padding(.vertical, 6)
                Divider()
            }
            if let selected {
                selected.makeView(panelContext)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .background(.background)
    }

    /// Build the context handed to a flanking panel from the live session.
    private var panelContext: ManuscriptPanelContext {
        let ns = session.source as NSString
        let range = session.selectedRange
        let safeLoc = min(max(0, range.location), ns.length)
        let safeLen = min(range.length, ns.length - safeLoc)
        let selectedText = safeLen > 0
            ? ns.substring(with: NSRange(location: safeLoc, length: safeLen)) : ""
        return ManuscriptPanelContext(
            manuscriptID: session.manuscriptID,
            source: $session.source,
            selectedRange: range,
            selectedText: selectedText,
            cursorPosition: $session.cursorPosition,
            format: session.format,
            svgPages: session.vm.svgPages,
            insertAtCursor: { text in insertAtCursor(text) },
            jumpToChar: { offset in session.cursorPosition = offset }
        )
    }

    /// Insert `text` at the caret (or replacing the selection) in the buffer.
    private func insertAtCursor(_ text: String) {
        let ns = session.source as NSString
        let range = session.selectedRange
        let loc = min(max(0, range.location), ns.length)
        let len = min(range.length, ns.length - loc)
        let updated = ns.replacingCharacters(in: NSRange(location: loc, length: len), with: text)
        session.source = updated
        session.cursorPosition = loc + (text as NSString).length
    }

    // MARK: Preview

    @ViewBuilder
    private var previewPane: some View {
        if session.format.previewKind == .renderedMarkdown {
            // Markdown renders live from the buffer — there is no compiled
            // artifact, so the pdfData path below would sit at "No preview yet".
            MarkdownPreviewTab(session: session)
        } else if session.latexPreviewUnavailable {
            ManuscriptLaTeXImprintPrompt(session: session)
        } else if let data = session.vm.pdfData {
            // Inline split: editor is already on-screen, so a preview click just
            // moves the caret (no tab switch). Forward sync keeps the preview
            // tracking the caret as the user writes.
            ManuscriptPDFPreview(
                data: data,
                cursorOffset: session.cursorPosition,
                sourceMapEntries: session.vm.sourceMapEntries,
                onInverseSync: { page, x, y in
                    let session = self.session
                    Task {
                        if let offset = await ManuscriptInverseSync.resolveOffset(
                            session: session, page: page, x: x, y: y) {
                            session.cursorPosition = offset
                        }
                    }
                })
        } else {
            VStack(spacing: 8) {
                if session.vm.isCompiling {
                    ProgressView()
                    Text("Compiling…").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No preview yet").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Strips

    // The pane TOGGLES that used to sit here moved to the window toolbar
    // (`ManuscriptEditorPaneToggles` in TabContentView / the editor window),
    // next to the sidebar + list toggles at the top left — one cluster for
    // every show/hide-a-pane control. The strip keeps compile STATUS only.
    private var compileStrip: some View {
        HStack(spacing: 8) {
            if session.latexPreviewUnavailable {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("LaTeX preview opens in imprint").foregroundStyle(.secondary)
                Button("Open in imprint") {
                    ManuscriptImprintHandoff.open(manuscriptID: session.manuscriptID)
                }
                .buttonStyle(.link)
            } else if session.vm.isCompiling {
                ProgressView().controlSize(.small)
                Text("Compiling").foregroundStyle(.secondary)
            } else if let err = session.vm.compilationError, !err.isEmpty {
                // Click the message → jump the editor to the first error.
                // The count badge → the full diagnostics panel.
                Button {
                    if let first = errorDiagnostics.first { jump(to: first) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(firstErrorLine(err))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
                .help("Jump to the error in the source")
                diagnosticsBadge
            } else if session.vm.pdfData != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Compiled").foregroundStyle(.secondary)
                if !warningDiagnostics.isEmpty {
                    diagnosticsBadge
                }
            }
            Spacer()
            Text(session.format.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .popover(isPresented: $showDiagnosticsPanel, arrowEdge: .top) {
            CompileDiagnosticsPanel(
                diagnostics: session.vm.compilationDiagnostics,
                onJump: { diagnostic in jump(to: diagnostic) }
            )
        }
    }

    // MARK: Diagnostics

    private var errorDiagnostics: [CompileDiagnostic] {
        session.vm.compilationDiagnostics.filter { $0.severity == .error }
    }

    private var warningDiagnostics: [CompileDiagnostic] {
        session.vm.compilationDiagnostics.filter { $0.severity != .error }
    }

    /// The badge summarising the diagnostic counts; opens the panel.
    private var diagnosticsBadge: some View {
        let errors = errorDiagnostics.count
        let warnings = warningDiagnostics.count
        let label: String
        if errors > 0 && warnings > 0 {
            label = "\(errors)⨯ \(warnings)⚠"
        } else if errors > 0 {
            label = errors == 1 ? "1 error" : "\(errors) errors"
        } else {
            label = warnings == 1 ? "1 warning" : "\(warnings) warnings"
        }
        return Button(label) { showDiagnosticsPanel = true }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Show all compiler diagnostics")
    }

    /// First line of the (possibly multi-error) summary, without the
    /// leading `error (line N):` prefix the panel already renders.
    private func firstErrorLine(_ summary: String) -> String {
        let first = summary.components(separatedBy: .newlines).first ?? summary
        if let diag = errorDiagnostics.first {
            if let line = diag.line { return "line \(line): \(diag.message)" }
            return diag.message
        }
        return first
    }

    /// Move the editor to a diagnostic: select the offending range when the
    /// compiler gave one, else land the caret on its line.
    private func jump(to diagnostic: CompileDiagnostic) {
        let source = session.source
        let range = diagnostic.editorRange(in: source)
            ?? diagnostic.editorOffset(in: source).map { NSRange(location: $0, length: 0) }
        guard let range else { return }
        logInfo(
            "diagnostic jump → line \(diagnostic.line.map(String.init) ?? "?") range \(range)",
            category: "compile")
        session.highlight(range: range)
    }

    private var conflictBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text("This manuscript was edited elsewhere.")
                .fontWeight(.medium)
            Spacer()
            Button("Keep mine") { session.keepMine() }
            Button("Take theirs") { session.takeExternal() }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
    }
}

/// The editor pane toggles (outline / comments / inspector / preview), for the
/// WINDOW TOOLBAR — placed beside the sidebar and list toggles at the top left
/// so every show/hide-a-pane control reads as one cluster. State is the same
/// `@AppStorage` keys `ManuscriptSourceTab` reads, so a toolbar click flips the
/// live editor with no plumbing.
public struct ManuscriptEditorPaneToggles: View {
    @AppStorage("manuscript.sourceTab.showPreview") private var showPreview = true
    @AppStorage("manuscript.sourceTab.showOutline") private var showOutline = false
    @AppStorage("manuscript.sourceTab.showComments") private var showComments = false
    @AppStorage("manuscript.sourceTab.showInspector") private var showInspector = false

    public init() {}

    public var body: some View {
        Toggle(isOn: $showOutline) {
            Image(systemName: "list.bullet.indent")
        }
        .toggleStyle(.button)
        .help("Toggle outline")
        Toggle(isOn: $showComments) {
            Image(systemName: "bubble.left.and.bubble.right")
        }
        .toggleStyle(.button)
        .help("Toggle comments")
        if !ManuscriptEditorEnvironment.shared.sidePanels.isEmpty {
            Toggle(isOn: $showInspector) {
                Image(systemName: "sidebar.squares.right")
            }
            .toggleStyle(.button)
            .help("Toggle inspector panels")
        }
        Toggle(isOn: $showPreview) {
            Image(systemName: "sidebar.right")
        }
        .toggleStyle(.button)
        .help("Toggle preview")
    }
}

/// The Source tab's comments column (GUI-meld plan §4 — "toggleable comments
/// column"). Store-backed via RustStoreAdapter (`imbib/comment` items keyed by
/// the manuscript UUID — the same items imprint's CommentService writes), so
/// the default chassis window and the legacy editor share one comment set.
/// New comments anchor to the current editor selection.
struct ManuscriptCommentsColumn: View {
    let session: ManuscriptEditorSession

    @State private var comments: [Comment] = []
    @State private var draft: String = ""

    /// The invisible sentinel imprint's ManuscriptCommentStore uses to carry
    /// isResolved/proposedText — stripped for display so it never shows.
    private static let metaSentinel = "\u{2063}\u{2063}imprint-meta:"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Comments")
                .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            Divider()
            if rootComments.isEmpty {
                Text("No comments")
                    .font(.callout).foregroundStyle(.tertiary).padding(10)
                Spacer()
            } else {
                List {
                    ForEach(rootComments) { comment in
                        commentRow(comment)
                    }
                }
                .listStyle(.plain)
            }
            Divider()
            composer
        }
        .background(.background)
        .task(id: session.manuscriptID) { reload() }
        .task {
            // Refresh when the manuscript (and thus its comments) mutate.
            for await event in ImbibImpressStore.shared.events.subscribe() {
                if case .itemsMutated(_, let ids) = event, ids.contains(session.manuscriptID) {
                    reload()
                }
            }
        }
    }

    private var rootComments: [Comment] {
        comments.filter { $0.parentCommentID == nil }
    }

    private func commentRow(_ comment: Comment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(comment.authorDisplayName ?? "Unknown")
                    .font(.caption).fontWeight(.medium)
                Spacer()
                Text(comment.dateCreated, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
                Button {
                    RustStoreAdapter.shared.deleteComment(comment.id)
                    reload()
                } label: {
                    Image(systemName: "trash").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if let snippet = comment.anchorText, !snippet.isEmpty {
                Text("“\(snippet.prefix(48))”")
                    .font(.caption2).foregroundStyle(.secondary).italic()
                    .lineLimit(1)
            }
            Text(displayText(comment.text))
                .font(.callout)
        }
        .padding(.vertical, 2)
    }

    private var composer: some View {
        HStack(spacing: 6) {
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .onSubmit(addComment)
            Button(action: addComment) {
                Image(systemName: "arrow.up.circle.fill")
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(8)
    }

    private func displayText(_ raw: String) -> String {
        if let r = raw.range(of: Self.metaSentinel) {
            return String(raw[..<r.lowerBound])
        }
        return raw
    }

    private func reload() {
        comments = RustStoreAdapter.shared.listCommentsForItem(itemId: session.manuscriptID)
    }

    private func addComment() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let range = session.selectedRange
        let ns = session.source as NSString
        let safeLoc = min(max(0, range.location), ns.length)
        let safeLen = min(range.length, ns.length - safeLoc)
        let snippet = safeLen > 0 ? ns.substring(with: NSRange(location: safeLoc, length: safeLen)) : ""
        let hash = RustStoreAdapter.shared.getManuscriptDetail(id: session.manuscriptID)?.bodyContentHash ?? ""

        RustStoreAdapter.shared.createAnchoredComment(
            itemId: session.manuscriptID,
            text: text,
            authorIdentifier: CommentService.shared.currentAuthorIdentifier,
            authorDisplayName: NSFullUserName(),
            anchorStart: safeLoc,
            anchorEnd: safeLoc + safeLen,
            anchorText: snippet,
            anchoredBodyHash: hash
        )
        draft = ""
        reload()
    }
}

/// A collapsible document outline for the Source tab (GUI-meld plan §4 —
/// "toggleable outline rail (jump-to-line)"). Sections come from
/// SectionExtractor; tapping one moves the editor caret to its start.
struct ManuscriptOutlineRail: View {
    let source: String
    let format: DocumentFormat
    let onJump: (Int) -> Void

    private var sections: [ExtractedSection] {
        SectionExtractor.extract(
            from: source,
            documentID: Self.stableDocID,
            format: format == .latex ? .latex : .typst
        )
    }

    // Outline doesn't persist section identity across manuscripts; a fixed
    // doc id keeps SectionExtractor's deterministic ids stable within a body.
    private static let stableDocID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Outline")
                .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            Divider()
            if sections.isEmpty {
                Text("No sections")
                    .font(.callout).foregroundStyle(.tertiary)
                    .padding(10)
                Spacer()
            } else {
                List(sections, id: \.id) { section in
                    Button {
                        // UTF-16, because the offset lands in
                        // `NSTextView.setSelectedRange`.
                        onJump(section.startUTF16)
                    } label: {
                        Text(section.title.isEmpty ? "(untitled)" : section.title)
                            .lineLimit(1)
                            .padding(.leading, CGFloat(max(0, section.level - 1)) * 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
        .background(.background)
    }
}

/// Minimal PDFKit preview for the compiled manuscript. Rebuilds its document
/// when the compiled bytes change; preserves scroll position otherwise.
/// Optionally reports clicks for inverse-sync (`onInverseSync`): a 1-indexed
/// page + PDF point in **top-left** origin. When `onInverseSync` is nil the
/// view behaves exactly as before (no-op click).
struct ManuscriptPDFPreview: NSViewRepresentable {
    let data: Data
    /// Caret offset in the source. When it moves, the preview scrolls to the
    /// matching region so the user never has to hunt for where they were.
    /// `nil` disables forward sync (e.g. a preview with no live editor).
    var cursorOffset: Int? = nil
    /// Compiled source map used to resolve `cursorOffset` → page + point.
    var sourceMapEntries: [SourceMapEntry] = []
    var onInverseSync: ((_ page: Int, _ x: Double, _ y: Double) -> Void)? = nil

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        let click = NSClickGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        // Only fire when a handler is present so text selection stays usable.
        click.isEnabled = onInverseSync != nil
        view.addGestureRecognizer(click)
        context.coordinator.clickRecognizer = click
        context.coordinator.entries = sourceMapEntries
        // First appearance (e.g. switching Source → Preview): land on the
        // caret's region rather than page 1.
        if let offset = cursorOffset {
            context.coordinator.requestScroll(offset: offset, in: view)
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        // Only rebuild when the bytes actually changed (avoids scroll reset).
        let rebuilt = context.coordinator.lastData != data
        if rebuilt {
            view.document = PDFDocument(data: data)
            context.coordinator.lastData = data
            // A recompile invalidates the previous scroll target.
            context.coordinator.lastSyncedOffset = nil
        }
        context.coordinator.onInverseSync = onInverseSync
        context.coordinator.clickRecognizer?.isEnabled = onInverseSync != nil
        context.coordinator.entries = sourceMapEntries

        if let offset = cursorOffset {
            context.coordinator.requestScroll(offset: offset, in: view, force: rebuilt)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(lastData: data, onInverseSync: onInverseSync) }

    final class Coordinator: NSObject {
        var lastData: Data
        var onInverseSync: ((_ page: Int, _ x: Double, _ y: Double) -> Void)?
        weak var clickRecognizer: NSClickGestureRecognizer?
        var entries: [SourceMapEntry] = []
        /// Last offset we scrolled to. Also set when the user clicks in the
        /// preview, so the caret move that click causes doesn't bounce the
        /// view back through forward sync.
        var lastSyncedOffset: Int?

        init(lastData: Data, onInverseSync: ((_ page: Int, _ x: Double, _ y: Double) -> Void)?) {
            self.lastData = lastData
            self.onInverseSync = onInverseSync
        }

        /// Ask the preview to show the region rendered from `offset`.
        ///
        /// Deduplicated on the offset, then retried until the view is actually
        /// scrollable. The retry is the load-bearing part: on a tab switch,
        /// `makeNSView` and the first `updateNSView` both run before PDFKit has
        /// laid the document out, and a `go(to:on:)` issued against a
        /// zero-height view is silently dropped — which looked exactly like
        /// "forward sync resolved the right page but the preview stayed at the
        /// beginning".
        func requestScroll(offset: Int, in view: PDFView, force: Bool = false) {
            guard force || offset != lastSyncedOffset else { return }
            lastSyncedOffset = offset
            attemptScroll(offset: offset, in: view, attemptsLeft: 8)
        }

        private func attemptScroll(offset: Int, in view: PDFView, attemptsLeft: Int) {
            // Not laid out yet (or no document): come back after the next pass.
            guard view.document != nil, view.bounds.height > 1 else {
                guard attemptsLeft > 0 else {
                    logInfo("forward-sync gave up: view never became scrollable",
                            category: "manuscript-sync")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.attemptScroll(offset: offset, in: view, attemptsLeft: attemptsLeft - 1)
                }
                return
            }
            scrollToSource(offset: offset, in: view)
        }

        /// Scroll the preview to the region rendered from `offset` in the
        /// source. No-op when the map is empty or the offset doesn't map.
        private func scrollToSource(offset: Int, in view: PDFView) {
            guard !entries.isEmpty, let document = view.document else {
                logInfo("forward-sync skipped: map=\(entries.count) doc=\(view.document != nil)",
                        category: "manuscript-sync")
                return
            }
            guard let region = SourceMapUtils.sourceToRender(
                entries: entries, sourceOffset: offset) else {
                logInfo("forward-sync: offset \(offset) maps nowhere", category: "manuscript-sync")
                return
            }
            guard region.page >= 0, region.page < document.pageCount,
                  let page = document.page(at: region.page) else { return }
            let pages = Set(entries.map(\.page)).sorted()
            let spans = entries.map { $0.sourceEnd }.max() ?? 0
            logInfo("""
                forward-sync: offset \(offset) → page \(region.page + 1)/\(document.pageCount) \
                region(x:\(Int(region.x)) y:\(Int(region.y)) w:\(Int(region.width)) h:\(Int(region.height))) \
                map[n=\(entries.count) pages=\(pages) maxSrcEnd=\(spans)]
                """, category: "manuscript-sync")

            // Source-map coordinates are top-left origin; PDF pages are
            // bottom-left. Mirror the conversion the click path uses.
            let pageBounds = page.bounds(for: .mediaBox)
            let target = CGRect(
                x: region.center.x - 50,
                y: (pageBounds.height - region.center.y) - 50,
                width: 100, height: 100)
            view.go(to: target, on: page)
        }

        /// Convert a click to (1-indexed page, top-left-origin PDF point) and
        /// report it. Geometry mirrors imprint's PDFPreviewView reference:
        /// `convert(_:to:page)` is zoom-independent, so autoScales/dark filters
        /// don't affect page-space coordinates.
        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let onInverseSync,
                  let pdfView = gesture.view as? PDFView else { return }
            let locationInView = gesture.location(in: pdfView)
            guard let page = pdfView.page(for: locationInView, nearest: true),
                  let pageIndex = pdfView.document?.index(for: page) else { return }
            let pagePoint = pdfView.convert(locationInView, to: page)
            let pageBounds = page.bounds(for: .mediaBox)
            let x = Double(pagePoint.x)
            let y = Double(pageBounds.height - pagePoint.y)  // bottom-left → top-left
            // Pre-claim the offset this click is about to produce, so the
            // resulting caret move doesn't scroll the preview out from under
            // the user's click.
            let resolved = SourceMapUtils.lookup(
                entries: entries, page: pageIndex, x: x, y: y)
            if resolved.found { lastSyncedOffset = resolved.sourceOffset }
            onInverseSync(pageIndex + 1, x, y)
        }
    }
}
#endif
