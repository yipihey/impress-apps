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

public struct ManuscriptSourceTab: View {

    @State private var session: ManuscriptEditorSession
    @AppStorage("manuscript.sourceTab.showPreview") private var showPreview = true
    @AppStorage("manuscript.sourceTab.showOutline") private var showOutline = false
    @AppStorage("manuscript.sourceTab.showComments") private var showComments = false
    @AppStorage("manuscript.sourceTab.showInspector") private var showInspector = false
    /// The id of the currently-selected flanking-inspector panel.
    @AppStorage("manuscript.sourceTab.inspectorPanel") private var inspectorPanelID = ""

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
            if showPreview {
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
        if let data = session.vm.pdfData {
            // Inline split: editor is already on-screen, so a preview click just
            // moves the caret (no tab switch).
            ManuscriptPDFPreview(data: data, onInverseSync: { page, x, y in
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

    private var compileStrip: some View {
        HStack(spacing: 8) {
            if session.vm.isCompiling {
                ProgressView().controlSize(.small)
                Text("Compiling").foregroundStyle(.secondary)
            } else if let err = session.vm.compilationError, !err.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err.components(separatedBy: .newlines).first ?? err)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else if session.vm.pdfData != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Compiled").foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.format.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.tertiary)
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
            if !sidePanels.isEmpty {
                Toggle(isOn: $showInspector) {
                    Image(systemName: "sidebar.squares.right")
                }
                .toggleStyle(.button)
                .help("Toggle assistant panels")
            }
            Toggle(isOn: $showPreview) {
                Image(systemName: "sidebar.right")
            }
            .toggleStyle(.button)
            .help("Toggle preview")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
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
                        onJump(section.start)
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
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        // Only rebuild when the bytes actually changed (avoids scroll reset).
        if context.coordinator.lastData != data {
            view.document = PDFDocument(data: data)
            context.coordinator.lastData = data
        }
        context.coordinator.onInverseSync = onInverseSync
        context.coordinator.clickRecognizer?.isEnabled = onInverseSync != nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(lastData: data, onInverseSync: onInverseSync) }

    final class Coordinator: NSObject {
        var lastData: Data
        var onInverseSync: ((_ page: Int, _ x: Double, _ y: Double) -> Void)?
        weak var clickRecognizer: NSClickGestureRecognizer?

        init(lastData: Data, onInverseSync: ((_ page: Int, _ x: Double, _ y: Double) -> Void)?) {
            self.lastData = lastData
            self.onInverseSync = onInverseSync
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
            onInverseSync(pageIndex + 1, x, y)
        }
    }
}
#endif
